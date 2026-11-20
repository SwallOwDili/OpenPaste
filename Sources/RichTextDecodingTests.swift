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

    print("PASS: rich text decoding checks (\(checks))")
}
