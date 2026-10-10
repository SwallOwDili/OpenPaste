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
    /// Scales fonts, keeps paragraph spacing, and gives unstyled runs black text so they stay legible in dark mode.
    static func prepare(_ source: NSAttributedString, scale: CGFloat, limit: Int = 30_000) -> NSAttributedString {
        let trimmed = source.length > limit ? source.attributedSubstring(from: NSRange(location: 0, length: limit)) : source
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
        result.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if value == nil { result.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        return result
    }
    /// Plain text styled like a document page.
    static func plain(_ text: String, size: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle(); style.lineSpacing = 3; style.paragraphSpacing = 6
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black, .paragraphStyle: style])
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
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = scrolls; scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.appearance = NSAppearance(named: .aqua)
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = scrolls
        view.drawsBackground = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        if maximumLines > 0 { view.textContainer?.maximumNumberOfLines = maximumLines; view.textContainer?.lineBreakMode = .byTruncatingTail }
        view.textContainerInset = inset
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.identity != identity, let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.identity = identity
        view.textStorage?.setAttributedString(text)
        view.scroll(.zero)
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
