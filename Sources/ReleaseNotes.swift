import AppKit

/// Release notes for the update dialog. A GitHub release body is Markdown that may carry HTML (centred pictures with
/// captions). Headings, list items, bold, inline code and web links are styled; other tags keep only their text.
/// Pictures are shown only when they come from this repository on GitHub: they get a placeholder at once and are
/// filled in by `ReleaseNoteImageLoader` off the main thread. Pictures from anywhere else are left out with their caption.
enum ReleaseNotes {
    enum Block: Equatable {
        case heading(Int, String)
        case bullet(String)
        case numbered(String, String)
        case paragraph(String)
        case image(URL, caption: String?)
    }

    /// One picture in the notes: the placeholder and its caption carry it as an attribute until the picture arrives.
    final class ImageSlot: NSObject {
        let url: URL
        init(url: URL) { self.url = url }
    }
    static let imageSlotKey = NSAttributedString.Key("OpenPasteReleaseNoteImage")

    /// Only pictures published with this repository on GitHub are loaded.
    static func isTrustedImage(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !url.path.contains("..") else { return false }
        switch url.host {
        case "github.com": return url.path.hasPrefix("/SwallOwDili/OpenPaste/releases/download/")
        case "raw.githubusercontent.com": return url.path.hasPrefix("/SwallOwDili/OpenPaste/")
        default: return false
        }
    }

    private static func firstMatch(_ text: String, _ pattern: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
    private static func stripTags(_ text: String) -> String {
        var text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</?[A-Za-z][^>]*>"#, with: "", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text
    }

    static func blocks(_ body: String) -> [Block] {
        var text = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        // An HTML paragraph with a picture becomes one picture block (with the <sub> caption, if any), or goes.
        var images: [Block] = []
        let marker = "\u{E000}image:"
        text = text.components(separatedBy: "\n\n").map { paragraph in
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("<"), trimmed.range(of: "<img", options: .caseInsensitive) != nil else { return paragraph }
            guard let source = firstMatch(trimmed, #"<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive)?.first,
                  let url = URL(string: stripTags(source)), isTrustedImage(url) else { return "" }
            let caption = firstMatch(trimmed, #"<sub>([\s\S]*?)</sub>"#, options: .caseInsensitive)
                .map { stripTags($0[0]).trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            images.append(.image(url, caption: caption))
            return marker + String(images.count - 1)
        }.joined(separator: "\n\n")
        text = text.replacingOccurrences(of: #"<img\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = stripTags(text)

        var result: [Block] = []
        var open: Block?
        func flush() { if let block = open { result.append(block) }; open = nil }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(marker), let index = Int(line.dropFirst(marker.count)), images.indices.contains(index) {
                flush(); result.append(images[index]); continue
            }
            // A line that is only a Markdown picture is a picture block; pictures inside text are dropped.
            if let parts = firstMatch(line, #"^!\[([^\]]*)\]\(([^)\s]+)\)$"#) {
                flush()
                if let url = URL(string: parts[1]), isTrustedImage(url) { result.append(.image(url, caption: nil)) }
                continue
            }
            let line2 = line.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line2.isEmpty || line2.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil { flush(); continue }
            if let parts = firstMatch(line2, #"^(#{1,6})\s+(.*?)(?:\s+#+)?\s*$"#) { flush(); result.append(.heading(parts[0].count, parts[1])); continue }
            if let parts = firstMatch(line2, #"^[-*+]\s+(.*)$"#) { flush(); open = .bullet(parts[0]); continue }
            if let parts = firstMatch(line2, #"^(\d+[.)])\s+(.*)$"#) { flush(); open = .numbered(parts[0], parts[1]); continue }
            // A wrapped line continues the open item or paragraph.
            switch open {
            case .bullet(let value): open = .bullet(value + " " + line2)
            case .numbered(let marker, let value): open = .numbered(marker, value + " " + line2)
            case .paragraph(let value): open = .paragraph(value + " " + line2)
            default: open = .paragraph(line2)
            }
        }
        flush()
        return result
    }

    /// Styled notes. With `imageWidth` 0 pictures are left out; otherwise each gets a placeholder of that width.
    static func attributed(_ body: String, fontSize: CGFloat = 12, imageWidth: CGFloat = 0) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, block) in blocks(body).enumerated() {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 4
            style.lineSpacing = 1
            var text = "", size = fontSize, weight = NSFont.Weight.regular
            switch block {
            case .image(let url, let caption):
                guard imageWidth > 0 else { continue }
                if output.length > 0 { output.append(NSAttributedString(string: "\n")) }
                output.append(imageBlock(url: url, caption: caption, width: imageWidth, fontSize: fontSize, first: index == 0))
                continue
            case .heading(let level, let value):
                text = value
                size = level <= 2 ? fontSize + 3 : fontSize + 1
                weight = .semibold
                style.paragraphSpacingBefore = index == 0 ? 0 : 8
            case .bullet(let value):
                text = "•\t" + value
                hang(style, fontSize: fontSize)
            case .numbered(let marker, let value):
                text = marker + "\t" + value
                hang(style, fontSize: fontSize)
            case .paragraph(let value):
                text = value
            }
            if output.length > 0 { output.append(NSAttributedString(string: "\n")) }
            let line = inline(text, font: .systemFont(ofSize: size, weight: weight))
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            output.append(line)
        }
        if output.length == 0 { output.append(NSAttributedString(string: "该版本没有提供更新说明。", attributes: [.font: NSFont.systemFont(ofSize: fontSize)])) }
        let whole = NSRange(location: 0, length: output.length)
        output.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            if value == nil { output.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range) }
        }
        return output
    }

    /// Placeholder picture (a soft rounded box) followed by the caption; both carry the slot until the picture arrives.
    private static func imageBlock(url: URL, caption: String?, width: CGFloat, fontSize: CGFloat, first: Bool) -> NSAttributedString {
        let slot = ImageSlot(url: url)
        let placeholderSize = NSSize(width: width, height: (width * 0.42).rounded())
        let placeholder = NSImage(size: placeholderSize, flipped: false) { rect in
            NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = placeholder
        attachment.bounds = NSRect(origin: .zero, size: placeholderSize)
        let pictureStyle = NSMutableParagraphStyle()
        pictureStyle.alignment = .center
        pictureStyle.paragraphSpacingBefore = first ? 0 : 6
        pictureStyle.paragraphSpacing = caption == nil ? 8 : 3
        let block = NSMutableAttributedString(attachment: attachment)
        block.addAttribute(.paragraphStyle, value: pictureStyle, range: NSRange(location: 0, length: block.length))
        if let caption {
            let captionStyle = NSMutableParagraphStyle()
            captionStyle.alignment = .center
            captionStyle.paragraphSpacing = 8
            block.append(NSAttributedString(string: "\n" + caption, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize - 1.5), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: captionStyle]))
        }
        block.addAttribute(imageSlotKey, value: slot, range: NSRange(location: 0, length: block.length))
        return block
    }

    /// Puts a loaded picture in place of its placeholder, scaled to the placeholder's width; a missing picture removes
    /// the placeholder and caption. Main thread only.
    static func fill(_ slot: ImageSlot, with image: NSImage?, in storage: NSTextStorage, width: CGFloat) {
        var found: NSRange?
        storage.enumerateAttribute(imageSlotKey, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if (value as? ImageSlot) === slot { found = range; stop.pointee = true }
        }
        guard let range = found else { return }
        storage.beginEditing()
        defer { storage.endEditing() }
        guard let image, image.size.width > 0, image.size.height > 0 else {
            // Take the line break before the block too, so no empty paragraph is left behind.
            var remove = range
            if remove.location > 0, (storage.string as NSString).character(at: remove.location - 1) == 10 {
                remove = NSRange(location: remove.location - 1, length: remove.length + 1)
            }
            storage.deleteCharacters(in: remove)
            return
        }
        let shown = min(width, image.size.width)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: shown, height: (shown * image.size.height / image.size.width).rounded())
        var attributes = storage.attributes(at: range.location, effectiveRange: nil)
        attributes[.attachment] = attachment
        storage.replaceCharacters(in: NSRange(location: range.location, length: 1),
                                  with: NSAttributedString(string: String(Character(UnicodeScalar(NSTextAttachment.character)!)), attributes: attributes))
    }

    private static func hang(_ style: NSMutableParagraphStyle, fontSize: CGFloat) {
        let indent = fontSize * 1.4
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        style.defaultTabInterval = indent
        style.headIndent = indent
    }

    /// Bold, italics, inline code and web links within one line; anything that does not parse stays plain text.
    private static func inline(_ text: String, font: NSFont) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSMutableAttributedString(string: text, attributes: [.font: font])
        }
        let output = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                    runFont = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont]
            if let link = run.link, ["https", "http"].contains(link.scheme?.lowercased() ?? "") { attributes[.link] = link }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return output
    }
}

/// Loads the notes' pictures in the background: download and decoding never run on the main thread, which only swaps
/// each finished picture into the text. The dialog cancels what is still loading when it closes.
final class ReleaseNoteImageLoader {
    static let maxBytes = 8 << 20
    static let maxImages = 6
    private let session: URLSession
    private var tasks: [URLSessionDataTask] = []

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    func load(into storage: NSTextStorage, width: CGFloat, completion: (() -> Void)? = nil) {
        var slots: [ReleaseNotes.ImageSlot] = []
        storage.enumerateAttribute(ReleaseNotes.imageSlotKey, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let slot = value as? ReleaseNotes.ImageSlot, !slots.contains(where: { $0 === slot }) { slots.append(slot) }
        }
        // Pictures past the limit are removed rather than left as placeholders.
        for slot in slots.dropFirst(Self.maxImages) { ReleaseNotes.fill(slot, with: nil, in: storage, width: width) }
        final class Pending { var count = 0 }
        let pending = Pending()
        pending.count = min(slots.count, Self.maxImages)
        if pending.count == 0 { completion?(); return }
        for slot in slots.prefix(Self.maxImages) {
            let task = session.dataTask(with: URLRequest(url: slot.url)) { [weak storage] data, response, error in
                var image: NSImage?
                if error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let data, !data.isEmpty, data.count <= Self.maxBytes {
                    image = NSImage(data: data)
                }
                DispatchQueue.main.async {
                    if let storage { ReleaseNotes.fill(slot, with: image, in: storage, width: width) }
                    pending.count -= 1
                    if pending.count == 0 { completion?() }
                }
            }
            tasks.append(task)
            task.resume()
        }
    }

    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }
}
