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
    private var pages: [String: (light: NSColor, dark: NSColor)] = [:]
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
    /// Card page colour of a loaded rich clip for the given appearance; nil until `load` has finished.
    func page(_ clip: Clip, dark: Bool) -> NSColor? { pages[key(clip)].map { dark ? $0.dark : $0.light } }
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
            // HTML is imported here, off the main thread, after everything that loads a resource has been removed.
            if result == nil, let html = data(Self.htmlTypes), html.count <= Self.htmlByteLimit { result = HTMLImport.attributedString(from: html) }
            DispatchQueue.main.async {
                guard let self else { return }
                if let result, result.length > 0 {
                    // The page colour is taken from the full text, before it is cut down for the card.
                    if self.pages.count > 600 { self.pages.removeAll() }
                    self.pages[key] = (RichTextRendering.pageColor(for: result, dark: false), RichTextRendering.pageColor(for: result, dark: true))
                    self.cache.setObject(Self.truncated(result), forKey: key as NSString)
                } else { self.failed.insert(key) }
                let callbacks = self.pending.removeValue(forKey: key) ?? []
                let value = self.cache.object(forKey: key as NSString)
                callbacks.forEach { $0(value) }
            }
        }
    }
}

/// Prepares attributed text for display, on a page whose colour follows the text.
enum RichTextRendering {
    /// Lightness test: `(299 R + 587 G + 114 B) / 1000 > 0.55` in device RGB.
    static func isDark(_ color: NSColor) -> Bool { !isLight(color) }
    static func isLight(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.deviceRGB) else { return false }
        return (299 * Double(c.redComponent) + 587 * Double(c.greenComponent) + 114 * Double(c.blueComponent)) / 1000 > 0.55
    }
    /// Page of a plain text card: white in light appearance, #141414 in dark.
    static func plainPage(dark: Bool) -> NSColor { dark ? NSColor(srgbRed: 20.0 / 255, green: 20.0 / 255, blue: 20.0 / 255, alpha: 1) : .white }
    /// Footer text (character count, quick-paste index): black 50% on a light page, white 55% on a dark one.
    static func footerColor(onDark: Bool) -> NSColor { onDark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.5) }
    /// Page under mostly light text.
    static let darkPage = NSColor(srgbRed: 30.0 / 255, green: 30.0 / 255, blue: 30.0 / 255, alpha: 1)
    /// Colour of text that names none: black 85% on a light page, white 85% on a dark one.
    static func labelColor(onDark: Bool) -> NSColor { (onDark ? NSColor.white : NSColor.black).withAlphaComponent(0.85) }
    /// Page colour for rich text (issue #29). Within the first `limit` characters: the
    /// foreground colour covering the most characters (unset counts as the label colour of the appearance)
    /// decides the default page, #1E1E1E under light text and white otherwise; the background colour covering
    /// the most characters (unset counts as that default) becomes the page. A translucent winner falls back
    /// to white, or the window background in dark appearance. Explicit colours are never changed.
    static func pageColor(for text: NSAttributedString, dark: Bool, limit: Int = 20_000) -> NSColor {
        let length = min(text.length, limit)
        func dominant(_ key: NSAttributedString.Key, unset: NSColor) -> NSColor {
            var counts: [(color: NSColor, count: Int)] = []
            var covered = 0
            text.enumerateAttribute(key, in: NSRange(location: 0, length: length), options: []) { value, range, _ in
                guard let color = value as? NSColor else { return }
                covered += range.length
                if let index = counts.firstIndex(where: { $0.color == color }) { counts[index].count += range.length }
                else { counts.append((color, range.length)) }
            }
            counts.append((unset, length - covered))
            var best = counts[0]
            for entry in counts.dropFirst() where entry.count > best.count { best = entry }
            return best.color
        }
        let foreground = dominant(.foregroundColor, unset: labelColor(onDark: dark))
        let page = dominant(.backgroundColor, unset: isLight(foreground) ? darkPage : .white)
        guard (page.usingColorSpace(.deviceRGB)?.alphaComponent ?? 1) < 1 else { return page }
        guard dark else { return .white }
        var window = NSColor(srgbRed: 0.196, green: 0.196, blue: 0.196, alpha: 1)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { window = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? window }
        return window
    }
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
    /// Scales fonts, keeps paragraph spacing, and gives runs without a colour the label colour of the page
    /// (`onDark`: the page from `pageColor` is not light). Runs with a colour keep it.
    static func prepare(_ source: NSAttributedString, scale: CGFloat, limit: Int = 30_000, onDark: Bool = false, page: NSColor? = nil) -> NSAttributedString {
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
        result.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if value == nil { result.addAttribute(.foregroundColor, value: labelColor(onDark: onDark), range: range) }
        }
        if let page { ensureVisible(result, on: page) }
        return result
    }

    /// Contrast below which a run's own colour counts as practically invisible (WCAG ratio). Low on purpose:
    /// red, blue and the dim comment colours of code themes stay as written.
    static let minimumContrast = 2.0

    /// Runs whose colour is practically invisible on their background (page, then table block, then text
    /// highlight) become black or white, whichever contrasts more. Links are drawn by the text view in the link colour.
    private static func ensureVisible(_ text: NSMutableAttributedString, on page: NSColor) {
        let pageRGB = srgb(page) ?? SIMD3(repeating: 1)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            guard attributes[.link] == nil, let color = attributes[.foregroundColor] as? NSColor else { return }
            var background = pageRGB
            for block in (attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks ?? [] { background = composite(block.backgroundColor, over: background) }
            background = composite(attributes[.backgroundColor] as? NSColor, over: background)
            let backdrop = luminance(background)
            let foreground = luminance(composite(color, over: background))
            guard (max(foreground, backdrop) + 0.05) / (min(foreground, backdrop) + 0.05) < minimumContrast else { return }
            let blackContrast = (backdrop + 0.05) / 0.05, whiteContrast = 1.05 / (backdrop + 0.05)
            text.addAttribute(.foregroundColor, value: whiteContrast > blackContrast ? NSColor.white : NSColor.black, range: range)
        }
    }
    private static func srgb(_ color: NSColor) -> SIMD3<Double>? {
        color.usingColorSpace(.sRGB).map { SIMD3(Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)) }
    }
    private static func composite(_ color: NSColor?, over background: SIMD3<Double>) -> SIMD3<Double> {
        guard let color, let rgb = srgb(color) else { return background }
        let opacity = Double(color.usingColorSpace(.sRGB)?.alphaComponent ?? 1)
        return rgb * opacity + background * (1 - opacity)
    }
    private static func luminance(_ color: SIMD3<Double>) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
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
/// (SwiftUI's Text drops paragraph styles). Its appearance follows the page: light, or dark when `dark`.
struct RichTextView: NSViewRepresentable {
    let text: NSAttributedString
    let identity: String
    var scrolls = true
    var inset = NSSize.zero
    var maximumLines = 0
    var dark = false

    final class Coordinator { var identity = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = RichTextScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = scrolls; scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
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
        scroll.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        scroll.pending = text
        scroll.applyPending()
    }
}

/// Rich card body: the clip's own fonts, colours, spacing and links on a page whose colour follows the
/// text (reported through `page`), fading out at the bottom instead of being cut off.
struct RichTextCardBody: View {
    let clip: Clip
    let compact: Bool
    var page: Binding<NSColor?> = .constant(nil)
    @Environment(\.colorScheme) private var colorScheme
    @State private var rendered: NSAttributedString?
    @State private var version = ""
    private var onDark: Bool { RichTextRendering.isDark(page.wrappedValue ?? RichTextRendering.plainPage(dark: colorScheme == .dark)) }

    var body: some View {
        Group {
            if let rendered {
                RichTextView(text: rendered, identity: version + (onDark ? ":dark" : ":light"), scrolls: false, dark: onDark).allowsHitTesting(false)
            } else {
                Text(String(clip.text.prefix(1500))).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .topLeading)
                    .environment(\.colorScheme, onDark ? .dark : .light).foregroundStyle(Color(nsColor: RichTextRendering.labelColor(onDark: onDark)))
            }
        }
        // No line limit and no fade; the card's height cuts the text off.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        .onAppear { if version != clip.fingerprint { load() } }
        .onChange(of: clip.fingerprint) { _, _ in load() }
        .onChange(of: colorScheme) { _, _ in load() }
    }
    private func load() {
        let requested = clip.fingerprint, dark = colorScheme == .dark
        version = requested
        RichTextCache.shared.load(clip) { value in
            guard version == requested else { return }
            let color = value == nil ? nil : RichTextCache.shared.page(clip, dark: dark)
            page.wrappedValue = color
            guard let value, RichTextCache.hasVisibleFormatting(value) else { rendered = nil; return }
            rendered = RichTextRendering.prepare(value, scale: 1, onDark: color.map { RichTextRendering.isDark($0) } ?? false, page: color)
        }
    }
}
