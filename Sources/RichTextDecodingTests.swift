import AppKit

/// Covers rich text font, contrast, and pasteboard export behavior.
/// Uses only fixtures and uniquely named pasteboards; never touches the general pasteboard.
func runRichTextDecodingTests() {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { print("FAIL: \(label)"); exit(1) }
        checks += 1
        print("PASS: \(label)")
    }
    func fonts(_ text: NSAttributedString) -> [NSFont] {
        var result: [NSFont] = []
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in if let font = value as? NSFont { result.append(font) } }
        return result
    }
    func hasLastResort(_ text: NSAttributedString) -> Bool { fonts(text).contains { $0.fontName.hasPrefix("LastResort") } }
    func colors(_ text: NSAttributedString) -> [String] {
        var result: [String] = []
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let color = (value as? NSColor)?.usingColorSpace(.sRGB) { result.append("\(range.location):\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))") }
        }
        return result
    }
    // Same structure VSCode puts on the pasteboard for a copied selection, with the family
    // forced to the placeholder font the reporter's machine resolved to.
    func vscodeHTML(_ family: String) -> Data {
        Data(("<meta charset='utf-8'><div style=\"color: #cccccc;background-color: #1f1f1f;font-family: \(family), monospace;font-weight: normal;font-size: 12px;line-height: 18px;white-space: pre;\">"
            + "<div><span style=\"color: #569cd6;\">const</span><span style=\"color: #cccccc;\"> </span><span style=\"color: #4fc1ff;\">a</span><span style=\"color: #cccccc;\"> = </span><span style=\"color: #b5cea8;\">1</span><span style=\"color: #cccccc;\">;</span></div>"
            + "<div><span style=\"color: #6a9955;\">// 中文注释 café</span></div></div>").utf8)
    }
    let plain = "const a = 1;\n// 中文注释 café"
    func clip(_ html: Data, text: String = plain) -> Clip {
        Clip(source: "Fixture", sourceID: "com.microsoft.VSCode", kind: "文字", title: text, text: text,
             parts: [[ClipPart(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8)), ClipPart(type: NSPasteboard.PasteboardType.html.rawValue, data: html)]])
    }

    let brokenHTML = vscodeHTML("LastResort")
    let imported = NSAttributedString(html: brokenHTML, documentAttributes: nil)!
    check(hasLastResort(imported), "fixture reproduces the issue: HTML import resolves the font to LastResort")
    check(!fonts(imported).isEmpty && fonts(imported).allSatisfy { $0.fontName.hasPrefix("LastResort") }, "fixture has only LastResort runs, like the reported VSCode cards")

    let repaired = RichTextRendering.repairingFonts(imported)
    check(!hasLastResort(repaired), "repair leaves no LastResort run")
    check(repaired.string == imported.string, "repair keeps the text unchanged")
    check(colors(repaired) == colors(imported) && colors(imported).count >= 4, "repair keeps every syntax colour run")
    check(fonts(repaired).allSatisfy { $0.isFixedPitch }, "an all-LastResort document gets the monospaced system font")
    check(zip(fonts(repaired), fonts(imported)).allSatisfy { $0.pointSize == $1.pointSize }, "repair keeps the font size")
    check(RichTextCache.hasVisibleFormatting(repaired), "repaired text still counts as formatted, so the card keeps its colours")
    check(!hasLastResort(RichTextRendering.prepare(imported, scale: 1)) && !hasLastResort(RichTextRendering.prepare(imported, scale: 1.3)), "card and preview rendering (prepare) never draw LastResort")

    let mixed = NSMutableAttributedString(string: "Title ", attributes: [.font: NSFont.systemFont(ofSize: 15)])
    mixed.append(NSAttributedString(string: "body", attributes: [.font: NSFont(name: "LastResort", size: 13) ?? NSFont.systemFont(ofSize: 13), .link: URL(string: "https://example.com")!]))
    if fonts(mixed).contains(where: { $0.fontName.hasPrefix("LastResort") }) {
        let fixed = RichTextRendering.repairingFonts(mixed)
        check(!hasLastResort(fixed) && !(fixed.attribute(.font, at: 6, effectiveRange: nil) as! NSFont).isFixedPitch, "LastResort among proportional text gets the proportional system font")
        check(fixed.attribute(.link, at: 6, effectiveRange: nil) as? URL == URL(string: "https://example.com"), "repair keeps links")
    } else {
        print("SKIP: NSFont(name: \"LastResort\") unavailable on this system; mixed-document case not checked")
    }

    let healthy = NSAttributedString(html: vscodeHTML("Menlo"), documentAttributes: nil)!
    check(fonts(healthy).contains { $0.fontName == "Menlo-Regular" }, "default VSCode font resolves to Menlo")
    check(RichTextRendering.repairingFonts(healthy) === healthy, "a document without LastResort is returned as the same object, untouched")

    let broken = clip(brokenHTML)
    check(!hasLastResort(broken.attributedText), "Clip.attributedText (preview, editor, merged paste) has no LastResort")

    let store = Store(ephemeral: true)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    check(store.restore(broken, plain: false, pasteboard: board), "single restore succeeds")
    check(board.data(forType: .html) == brokenHTML && board.string(forType: .string) == plain, "single restore writes the original HTML bytes unchanged")

    let second = clip(vscodeHTML("LastResort"), text: "second")
    check(store.restoreMany([broken, second], plain: false, pasteboard: board), "merged restore succeeds")
    let rtf = board.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
    check(rtf != nil && !hasLastResort(rtf!), "merged paste RTF carries no LastResort font")
    check(String(data: board.data(forType: .rtf) ?? Data(), encoding: .ascii)?.contains("LastResort") == false, "merged paste RTF font table does not name LastResort")

    let contrastText = "OpenPaste contrast test"
    let whiteRTF = Data(#"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}{\colortbl;\red255\green255\blue255;}\f0\fs26\b\cf1 OpenPaste contrast test}"#.utf8)
    let whiteHTML = Data("<strong style=\"color: #fff\">\(contrastText)</strong>".utf8)
    var white = clip(whiteHTML, text: contrastText)
    white.parts[0].append(ClipPart(type: NSPasteboard.PasteboardType.rtf.rawValue, data: whiteRTF))
    func foreground(_ text: NSAttributedString, at index: Int = 0) -> NSColor? {
        (text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
    }
    let black = NSColor.black.usingColorSpace(.sRGB)
    let opaqueWhite = NSColor.white.usingColorSpace(.sRGB)
    let originalWhite = white.attributedText
    check(foreground(originalWhite) == opaqueWhite, "issue #29 fixture imports opaque white")
    for (view, display) in [("history card", RichTextRendering.prepare(originalWhite, scale: 1)),
                            ("full preview", FullItemPreview.pageText(white))] {
        check(foreground(display) == black && display.string == contrastText, "white RTF is readable in the \(view)")
        check(fonts(display).first?.fontDescriptor.symbolicTraits.contains(.bold) == true, "the \(view) keeps bold text")
    }
    let htmlOnly = clip(whiteHTML, text: contrastText).attributedText
    check(foreground(htmlOnly) == opaqueWhite && foreground(RichTextRendering.prepare(htmlOnly, scale: 1)) == black, "white HTML is corrected for display too")

    let mixedColors = NSMutableAttributedString(string: "abcdef", attributes: [.foregroundColor: NSColor.white])
    let navy = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.5, alpha: 1)
    let link = URL(string: "https://example.com")!
    mixedColors.addAttribute(.backgroundColor, value: NSColor.black, range: NSRange(location: 1, length: 1))
    mixedColors.addAttributes([.foregroundColor: navy, .link: link], range: NSRange(location: 2, length: 1))
    mixedColors.addAttribute(.foregroundColor, value: NSColor.black.withAlphaComponent(0.1), range: NSRange(location: 3, length: 1))
    mixedColors.addAttribute(.backgroundColor, value: NSColor.black.withAlphaComponent(0.25), range: NSRange(location: 4, length: 1))
    mixedColors.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 5, length: 1))
    mixedColors.addAttribute(.backgroundColor, value: NSColor.black, range: NSRange(location: 5, length: 1))
    let readable = RichTextRendering.prepare(mixedColors, scale: 1)
    check(foreground(readable) == black && foreground(readable, at: 1) == opaqueWhite, "identical white runs are handled according to their own backgrounds")
    check(foreground(readable, at: 2) == navy && readable.attribute(.link, at: 2, effectiveRange: nil) as? URL == link, "readable colors and link attributes survive")
    check(foreground(readable, at: 3) == black && foreground(readable, at: 4) == black, "translucent foregrounds and backgrounds are composited")
    check(foreground(readable, at: 5) == opaqueWhite, "dark text on a dark background becomes light")
    check(readable.attribute(.backgroundColor, at: 1, effectiveRange: nil) as? NSColor == .black, "preview keeps the original background")

    let table = NSTextTableBlock(table: NSTextTable(), startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
    table.backgroundColor = .black
    let paragraph = NSMutableParagraphStyle()
    paragraph.textBlocks = [table]
    let tableText = NSAttributedString(string: "Cell", attributes: [.foregroundColor: NSColor.white, .paragraphStyle: paragraph])
    check(foreground(RichTextRendering.prepare(tableText, scale: 1)) == opaqueWhite, "white text remains white in a dark rich-text table cell")

    check(foreground(originalWhite) == opaqueWhite && foreground(white.attributedText) == opaqueWhite, "preparing the previews leaves both source attributed text and clip unchanged")
    check(store.restore(white, plain: false, pasteboard: board), "white rich text restores after previewing")
    check(board.data(forType: .rtf) == whiteRTF && board.data(forType: .html) == whiteHTML &&
          board.data(forType: .string) == Data(contrastText.utf8), "pasteboard receives the exact original white RTF, HTML, and plain bytes")
    check(store.restore(white, plain: true, pasteboard: board) && board.data(forType: .rtf) == nil &&
          board.data(forType: .html) == nil && board.string(forType: .string) == contrastText, "explicit plain-text copy strips rich formats")
    let invalid = FullItemPreview.pageText(clip(Data(), text: contrastText))
    check(invalid.string == contrastText && foreground(invalid) == black, "unreadable rich data falls back to legible plain text")

    // Cost evidence only (not asserted, to keep the check deterministic): one pass over font runs.
    let large = NSMutableAttributedString()
    let lastResort = fonts(imported)[0]
    for index in 0..<3_000 { large.append(NSAttributedString(string: "token\(index % 10) ", attributes: [.font: lastResort, .foregroundColor: index % 2 == 0 ? NSColor.red : NSColor.blue])) }
    let start = DispatchTime.now().uptimeNanoseconds
    let largeRepaired = RichTextRendering.repairingFonts(large)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    check(!hasLastResort(largeRepaired) && largeRepaired.length == large.length, "large document (\(large.length) chars, 3,000 runs) is fully repaired")
    print(String(format: "INFO: repairingFonts on %d chars / 3,000 runs took %.2f ms", large.length, elapsed))
    let previewStart = DispatchTime.now().uptimeNanoseconds
    let largePreview = RichTextRendering.prepare(large, scale: 1.3)
    let previewElapsed = Double(DispatchTime.now().uptimeNanoseconds - previewStart) / 1_000_000
    check(largePreview.string == large.string, "large rich preview retains every character")
    print(String(format: "INFO: rich preview preparation on %d chars / 3,000 runs took %.2f ms", large.length, previewElapsed))

    print("PASS: rich text decoding checks (\(checks))")
}
