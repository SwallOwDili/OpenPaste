import AppKit

/// Issue #22: rich text whose font resolves to LastResort draws every character as a boxed "?".
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

    // Cost evidence only (not asserted, to keep the check deterministic): one pass over font runs.
    let large = NSMutableAttributedString()
    let lastResort = fonts(imported)[0]
    for index in 0..<3_000 { large.append(NSAttributedString(string: "token\(index % 10) ", attributes: [.font: lastResort, .foregroundColor: index % 2 == 0 ? NSColor.red : NSColor.blue])) }
    let start = DispatchTime.now().uptimeNanoseconds
    let largeRepaired = RichTextRendering.repairingFonts(large)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    check(!hasLastResort(largeRepaired) && largeRepaired.length == large.length, "large document (\(large.length) chars, 3,000 runs) is fully repaired")
    print(String(format: "INFO: repairingFonts on %d chars / 3,000 runs took %.2f ms", large.length, elapsed))

    // Issue #29: the page colour follows the text colour; explicit colours are never changed.
    func hex(_ color: NSColor?) -> String {
        guard let c = color?.usingColorSpace(.sRGB) else { return "nil" }
        return String(format: "#%02X%02X%02X/%.2f", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()), c.alphaComponent)
    }
    func page(_ text: NSAttributedString, dark: Bool = false) -> String { hex(RichTextRendering.pageColor(for: text, dark: dark)) }
    func foreground(_ text: NSAttributedString, at index: Int = 0) -> String { hex(text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor) }
    func shown(_ text: NSAttributedString, dark: Bool = false) -> NSAttributedString {
        let pageColor = RichTextRendering.pageColor(for: text, dark: dark)
        return RichTextRendering.prepare(text, scale: 1, onDark: !RichTextRendering.isLight(pageColor), page: pageColor)
    }
    let bold = NSFont.boldSystemFont(ofSize: 13)
    check(RichTextRendering.isLight(.white) && !RichTextRendering.isLight(.black) && RichTextRendering.isLight(NSColor(srgbRed: 0.67, green: 0.7, blue: 0.75, alpha: 1))
          && !RichTextRendering.isLight(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)) && !RichTextRendering.isLight(NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)), "lightness test uses the 0.55 threshold")
    for (name, color) in [("#FF0000", NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)), ("#007AFF", NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1))] {
        let text = NSAttributedString(string: "coloured text", attributes: [.foregroundColor: color, .font: bold])
        check(page(text) == "#FFFFFF/1.00" && foreground(shown(text)) == hex(color), "\(name) on white keeps its colour and a white page")
    }
    let whiteRTF = NSAttributedString(rtf: Data(#"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}{\colortbl;\red255\green255\blue255;}\f0\fs26\b\cf1 OpenPaste contrast test}"#.utf8), documentAttributes: nil)!
    check(page(whiteRTF) == "#1E1E1E/1.00" && page(whiteRTF, dark: true) == "#1E1E1E/1.00" && foreground(shown(whiteRTF)) == "#FFFFFF/1.00"
          && fonts(shown(whiteRTF)).first?.fontDescriptor.symbolicTraits.contains(.bold) == true, "white RTF gets a #1E1E1E page, stays white and bold")
    let whiteHTML = NSAttributedString(html: Data("<strong style=\"color: #fff\">OpenPaste contrast test</strong>".utf8), documentAttributes: nil)!
    check(page(whiteHTML) == "#1E1E1E/1.00" && foreground(shown(whiteHTML)) == "#FFFFFF/1.00", "white HTML gets a #1E1E1E page too")
    let mostlyLight = NSMutableAttributedString(string: String(repeating: "a", count: 90), attributes: [.foregroundColor: NSColor(srgbRed: 0.67, green: 0.698, blue: 0.749, alpha: 1)])
    mostlyLight.append(NSAttributedString(string: String(repeating: "b", count: 10), attributes: [.font: bold]))
    check(page(mostlyLight) == "#1E1E1E/1.00" && foreground(shown(mostlyLight)) == "#ABB2BF/1.00" && foreground(shown(mostlyLight), at: 95) == "#FFFFFF/0.85",
          "mostly #ABB2BF text: dark page, original colour kept, uncoloured text turns white")
    let mostlyUnset = NSMutableAttributedString(string: "w", attributes: [.foregroundColor: NSColor.white])
    mostlyUnset.append(NSAttributedString(string: String(repeating: "x", count: 1_199), attributes: [.font: bold]))
    check(page(mostlyUnset) == "#FFFFFF/1.00" && foreground(shown(mostlyUnset)) == hex(.black) && foreground(shown(mostlyUnset), at: 5) == "#000000/0.85",
          "one white character among 1,199 uncoloured ones: white page, the white one turns black so it stays visible")
    check(page(mostlyUnset, dark: true) == "#1E1E1E/1.00" && foreground(shown(mostlyUnset, dark: true), at: 5) == "#FFFFFF/0.85",
          "uncoloured rich text follows the appearance: dark page and white text in dark mode")
    let onDarkBackground = NSAttributedString(string: "terminal", attributes: [.foregroundColor: NSColor.white, .backgroundColor: NSColor(srgbRed: 0.1, green: 0.1, blue: 0.2, alpha: 1)])
    check(page(onDarkBackground) == "#1A1A33/1.00" && foreground(shown(onDarkBackground)) == hex(.white), "the most common opaque text background becomes the page")
    let highlighted = NSMutableAttributedString(string: String(repeating: "n", count: 40), attributes: [.font: bold])
    highlighted.addAttributes([.foregroundColor: NSColor.white, .backgroundColor: NSColor.black], range: NSRange(location: 3, length: 4))
    let highlightedShown = shown(highlighted)
    check(page(highlighted) == "#FFFFFF/1.00" && foreground(highlightedShown, at: 4) == hex(.white) && hex(highlightedShown.attribute(.backgroundColor, at: 4, effectiveRange: nil) as? NSColor) == hex(.black),
          "white text in a black highlight on a white page keeps both colours")
    let translucent = NSAttributedString(string: "tinted", attributes: [.backgroundColor: NSColor.black.withAlphaComponent(0.25), .font: bold])
    check(page(translucent) == "#FFFFFF/1.00" && page(translucent, dark: true) != "#FFFFFF/1.00" && !RichTextRendering.isLight(RichTextRendering.pageColor(for: translucent, dark: true)),
          "a translucent dominant background falls back to white, or the window background in dark mode")
    let beyondLimit = NSMutableAttributedString(string: String(repeating: "d", count: 30), attributes: [.font: bold])
    beyondLimit.append(NSAttributedString(string: String(repeating: "l", count: 300), attributes: [.foregroundColor: NSColor.white]))
    check(hex(RichTextRendering.pageColor(for: beyondLimit, dark: false, limit: 40)) == "#FFFFFF/1.00" && page(beyondLimit) == "#1E1E1E/1.00", "only the first characters up to the limit are counted")
    // Mixed colours on one page: nothing is left invisible.
    func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ c: NSColor) -> Double {
            let r = c.usingColorSpace(.sRGB)!
            func linear(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r.redComponent) + 0.7152 * linear(r.greenComponent) + 0.0722 * linear(r.blueComponent)
        }
        let x = luminance(a), y = luminance(b); return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    func over(_ color: NSColor, _ background: NSColor) -> NSColor {
        let f = color.usingColorSpace(.sRGB)!, b = background.usingColorSpace(.sRGB)!, a = f.alphaComponent
        return NSColor(srgbRed: f.redComponent * a + b.redComponent * (1 - a), green: f.greenComponent * a + b.greenComponent * (1 - a), blue: f.blueComponent * a + b.blueComponent * (1 - a), alpha: 1)
    }
    let navy = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.5, alpha: 1)
    let sixRuns = NSMutableAttributedString(string: "abcdef", attributes: [.foregroundColor: NSColor.white])
    sixRuns.addAttribute(.backgroundColor, value: NSColor.black, range: NSRange(location: 1, length: 1))
    sixRuns.addAttributes([.foregroundColor: navy, .link: URL(string: "https://example.com")!], range: NSRange(location: 2, length: 1))
    sixRuns.addAttribute(.foregroundColor, value: NSColor.black.withAlphaComponent(0.1), range: NSRange(location: 3, length: 1))
    sixRuns.addAttribute(.backgroundColor, value: NSColor.black.withAlphaComponent(0.25), range: NSRange(location: 4, length: 1))
    sixRuns.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 5, length: 1))
    let sixRunsPage = RichTextRendering.pageColor(for: sixRuns, dark: false)
    let sixRunsShown = shown(sixRuns)
    for index in [0, 1, 3, 4, 5] {
        let attributes = sixRunsShown.attributes(at: index, effectiveRange: nil)
        let background = (attributes[.backgroundColor] as? NSColor).map { over($0, sixRunsPage) } ?? sixRunsPage
        let color = (attributes[.foregroundColor] as? NSColor) ?? .black
        check(contrast(over(color, background), background) >= RichTextRendering.minimumContrast, "sixRuns colours: character \(index) is visible on the dark page")
    }
    check(foreground(sixRunsShown, at: 0) == hex(.white) && foreground(sixRunsShown, at: 1) == hex(.white), "sixRuns colours: white text, and white on black, keep white")
    check(foreground(sixRunsShown, at: 2) == hex(navy), "sixRuns colours: a link keeps its colour (the text view draws links)")
    check(foreground(sixRunsShown, at: 3) == hex(.white) && foreground(sixRunsShown, at: 5) == hex(.white), "sixRuns colours: dark text on the dark page turns white")
    check(hex(RichTextRendering.plainPage(dark: false)) == "#FFFFFF/1.00" && hex(RichTextRendering.plainPage(dark: true)) == "#141414/1.00", "plain text cards use white, or #141414 in dark mode")
    check(hex(RichTextRendering.footerColor(onDark: false)) == "#000000/0.50" && hex(RichTextRendering.footerColor(onDark: true)) == "#FFFFFF/0.55", "footer text is black 50% on light pages and white 55% on dark ones")
    var whiteClip = clip(Data("<strong style=\"color: #fff\">OpenPaste contrast test</strong>".utf8), text: "OpenPaste contrast test")
    whiteClip.parts[0].append(ClipPart(type: NSPasteboard.PasteboardType.rtf.rawValue, data: Data(#"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}{\colortbl;\red255\green255\blue255;}\f0\fs26\b\cf1 OpenPaste contrast test}"#.utf8)))
    let preview = FullItemPreview.page(whiteClip, dark: false)
    check(hex(preview.color) == "#1E1E1E/1.00" && foreground(preview.text) == "#FFFFFF/1.00" && preview.text.string == "OpenPaste contrast test", "the space preview uses the same page and colours")
    check(whiteClip.exportParts().flatMap { $0 }.first { $0.type == NSPasteboard.PasteboardType.rtf.rawValue }?.data == whiteClip.parts[0].last?.data && whiteClip.parts[0].last?.type == NSPasteboard.PasteboardType.rtf.rawValue, "the original RTF bytes are untouched")

    print("PASS: rich text decoding checks (\(checks))")
}
