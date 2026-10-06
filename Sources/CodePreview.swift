import AppKit
import SwiftUI

// Preview styling is separate from original bytes; missing rich representations are generated only on export.
enum CodeSyntax {
    private static let languages = NSCache<NSString, NSString>()
    static func language(_ text: String) -> String? {
        let key = String(text.prefix(12000)) as NSString
        if let cached = languages.object(forKey: key) { return cached.length == 0 ? nil : cached as String }
        let result = detect(text)
        languages.countLimit = 300; languages.setObject((result ?? "") as NSString, forKey: key)
        return result
    }
    private static func detect(_ text: String) -> String? {
        let s = String(text.prefix(12000))
        if let data = s.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data), value is [String: Any] || value is [Any] { return "JSON" }
        let patterns: [(String, String)] = [
            ("TypeScript", #"\b(interface|type)\s+\w+\s*[={]|:\s*(string|boolean|number)\b"#),
            ("JavaScript", #"\b(const|let|var)\s+\w+\s*=|\bfunction\s+\w+\s*\(|=>\s*\{"#),
            ("Python", #"(?m)^\s*(def\s+\w+\(.*\):|class\s+\w+.*:|from\s+\w+\s+import\s+)"#),
            ("Swift", #"\b(?:Text|Button|HStack|VStack|Picker|Toggle)\s*\([\s\S]{0,2000}?\.(?:font|foregroundStyle|padding|frame|keyboardShortcut)\s*\(|\bfunc\s+\w+\s*\(|\b(struct|enum)\s+\w+\s*[:{]"#),
            ("SQL", #"(?i)\bSELECT\s+.+\s+FROM\b|\bCREATE\s+TABLE\b|\bINSERT\s+INTO\b"#),
            ("HTML", #"<(!DOCTYPE\s+html|html|div|span|script|body)\b[^>]*>"#),
            ("CSS", #"[.#][\w-]+\s*\{\s*[\w-]+\s*:"#),
            ("Shell", #"(?m)^#!.*\b(bash|zsh|sh)\b|^\s*(export\s+\w+=|for\s+\w+\s+in\s+.*;\s*do)"#),
            ("Code", #"\b(public|private)\s+(static\s+)?(class|void|int|String)\s+\w+"#)
        ]
        return patterns.first { s.range(of: $0.1, options: .regularExpression) != nil }?.0
    }
    private static let cache = NSCache<NSString, NSAttributedString>()
    static func highlighted(_ source: String) -> NSAttributedString {
        let key = source as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let out = NSMutableAttributedString(string: source, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor(calibratedWhite: 0.88, alpha: 1)])
        let rules: [(String, NSColor)] = [
            (#"\b\d+(?:\.\d+)?\b"#, .systemOrange),
            (#"\b(?:const|let|var|function|return|await|async|new|if|else|for|while|import|from|export|def|class|struct|enum|func|public|private|static|void|interface|type|SELECT|FROM|WHERE|INSERT|INTO|CREATE|TABLE|true|false|null|nil|None|True|False)\b"#, .systemPink),
            (#"\b[A-Za-z_$][\w$]*(?=\s*\()"#, .systemBlue),
            (#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#, .systemGreen),
            (#"(?m)//[^\n]*|/\*[\s\S]*?\*/|^\s*#[^\n]*"#, .systemGray)
        ]
        let range = NSRange(location: 0, length: out.length)
        for (pattern, color) in rules { if let regex = try? NSRegularExpression(pattern: pattern) { for match in regex.matches(in: source, range: range) { out.addAttribute(.foregroundColor, value: color, range: match.range) } } }
        cache.countLimit = 100; cache.setObject(out, forKey: key)
        return out
    }
}

struct CodeCardBody: View {
    let text: String
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(CodeSyntax.language(text) ?? "Code").font(.system(size: 10, weight: .medium)).foregroundStyle(.gray)
            Text(AttributedString(CodeSyntax.highlighted(String(text.prefix(3000))))).lineLimit(compact ? 3 : 9).frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
struct FullCodePreview: View {
    let text: String
    var body: some View {
        GeometryReader { geometry in
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 16) {
                Text((1...max(1, text.components(separatedBy: "\n").count)).map(String.init).joined(separator: "\n")).font(.system(size: 13, design: .monospaced)).foregroundStyle(.gray)
                Text(AttributedString(CodeSyntax.highlighted(String(text.prefix(200000))))).fixedSize(horizontal: true, vertical: true).textSelection(.enabled)
            }.padding(20).frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
        }.background(Color(white: 0.14))
        }
    }
}


extension Clip {
    func exportParts() -> [[ClipPart]] {
        guard kind == "文字", CodeSyntax.language(text) != nil, text.utf8.count <= 200000 else { return parts }
        let types = parts.flatMap { $0.map(\.type) }
        guard !types.contains("public.rtf"), !types.contains("public.html") else { return parts }
        let rich = NSMutableAttributedString(attributedString: CodeSyntax.highlighted(text))
        let full = NSRange(location: 0, length: rich.length)
        rich.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if let color = value as? NSColor, color == NSColor(calibratedWhite: 0.88, alpha: 1) { rich.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        var result = parts
        if result.isEmpty { result = [[ClipPart(type: "public.utf8-plain-text", data: Data(text.utf8))]] }
        for (type, format) in [("public.rtf", NSAttributedString.DocumentType.rtf), ("public.html", NSAttributedString.DocumentType.html)] {
            if let data = try? rich.data(from: full, documentAttributes: [.documentType: format]) { result[0].append(ClipPart(type: type, data: data)) }
        }
        return result
    }
}
func runCodeStyleTests() {
    let text = #"Text(store.shortcutNotice.isEmpty ? "使用组合键" : store.shortcutNotice).font(.caption).foregroundStyle(.secondary)"#
    precondition(CodeSyntax.language(text) == "Swift")
    precondition(CodeSyntax.language("文字字体用什么颜色？") == nil)
    let clip = Clip(source: "测试", sourceID: "", kind: "文字", title: text, text: text, parts: [[ClipPart(type: "public.utf8-plain-text", data: Data(text.utf8))]])
    let parts = clip.exportParts()[0]
    precondition(parts.first?.data == Data(text.utf8))
    precondition(clip.parts[0].count == 1)
    for type in ["public.rtf", "public.html"] {
        let data = parts.first { $0.type == type }!.data
        let rich = try! NSAttributedString(data: data, options: [.documentType: type == "public.rtf" ? NSAttributedString.DocumentType.rtf : NSAttributedString.DocumentType.html], documentAttributes: nil)
        precondition(rich.string.trimmingCharacters(in: .newlines) == text)
        precondition(rich.attribute(.font, at: 0, effectiveRange: nil) != nil)
    }
    var original = clip
    original.parts[0].append(ClipPart(type: "public.html", data: Data("<pre style='color:red'>original</pre>".utf8)))
    precondition(original.exportParts()[0].count == original.parts[0].count && original.exportParts()[0][1].data == original.parts[0][1].data)
    let store = Store(ephemeral: true)
    let pb = NSPasteboard.withUniqueName()
    precondition(store.restore(clip, plain: false, pasteboard: pb))
    precondition(pb.data(forType: .rtf) != nil && pb.data(forType: .html) != nil && pb.string(forType: .string) == text)
    precondition(store.restore(clip, plain: true, pasteboard: pb))
    precondition(pb.data(forType: .rtf) == nil && pb.data(forType: .html) == nil && pb.string(forType: .string) == text)
    pb.releaseGlobally()
    print("PASS: SwiftUI fragment detection, rich RTF/HTML code export, original rich bytes retained, original text unchanged, plain paste excludes styling")
}
