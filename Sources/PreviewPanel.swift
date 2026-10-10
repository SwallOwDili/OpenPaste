import AppKit
import SwiftUI
import ImageIO
import NaturalLanguage

/// Facts shown under a preview, e.g. "134 characters · 4 words · 10 lines".
enum PreviewMetadata {
    static func textSummary(_ text: String) -> String {
        let sample = text.count > 200_000 ? String(text.prefix(200_000)) : text
        var words = 0
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sample
        tokenizer.enumerateTokens(in: sample.startIndex..<sample.endIndex) { _, _ in words += 1; return true }
        let lines = sample.isEmpty ? 0 : sample.components(separatedBy: "\n").count
        let suffix = text.count > 200_000 ? "+" : ""
        return "\(text.count) 个字符 · \(words)\(suffix) 个词 · \(lines)\(suffix) 行"
    }
    static func colorSummary(hex: String) -> String? {
        guard let color = CapturedColor.parse(hex)?.nsColor.usingColorSpace(.sRGB) else { return nil }
        let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
        let maximum = max(r, g, b), minimum = min(r, g, b), delta = maximum - minimum
        var hue: CGFloat = 0
        if delta > 0 {
            if maximum == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maximum == g { hue = (b - r) / delta + 2 } else { hue = (r - g) / delta + 4 }
            hue *= 60; if hue < 0 { hue += 360 }
        }
        let brightness = maximum
        let saturationB = maximum == 0 ? 0 : delta / maximum
        let lightness = (maximum + minimum) / 2
        let saturationL = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        func p(_ v: CGFloat) -> Int { Int((v * 100).rounded()) }
        return "RGB \(Int((r * 255).rounded())), \(Int((g * 255).rounded())), \(Int((b * 255).rounded())) · HSL \(Int(hue.rounded())), \(p(saturationL)), \(p(lightness)) · HSB \(Int(hue.rounded())), \(p(saturationB)), \(p(brightness))"
    }
    static func imageSize(_ clip: Clip) -> (width: Int, height: Int)? {
        for part in clip.parts.lazy.flatMap({ $0 }) where ["public.png", "public.tiff", "public.jpeg", "public.heic", "public.gif"].contains(part.type) {
            guard let source = CGImageSourceCreateWithData(part.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { continue }
            return (width, height)
        }
        return nil
    }
}

/// Popover content size per content type: compact for colours, shaped by the
/// picture for images, and a roomy reading pane for text, links and files.
enum PreviewLayout {
    static let header: CGFloat = 54
    static let footer: CGFloat = 42
    static let inset: CGFloat = 12
    static func size(for clip: Clip?, screen: CGSize) -> CGSize {
        let maxWidth = max(320, screen.width - 24)
        guard let clip else { return CGSize(width: min(390, maxWidth), height: 240) }
        if CapturedColor.parse(clip.text) != nil, clip.kind != "图片" { return CGSize(width: min(390, maxWidth), height: 310) }
        if clip.kind == "图片" {
            let limit = CGSize(width: min(650, maxWidth) - inset * 2, height: min(480, screen.height - 160) - header - footer)
            guard let pixels = PreviewMetadata.imageSize(clip), pixels.width > 0, pixels.height > 0 else { return CGSize(width: min(520, maxWidth), height: 400) }
            let scale = min(1, limit.width / CGFloat(pixels.width), limit.height / CGFloat(pixels.height))
            let width = max(430, CGFloat(pixels.width) * scale + inset * 2)
            let height = CGFloat(pixels.height) * scale + header + footer
            return CGSize(width: min(width, maxWidth), height: max(240, height))
        }
        if clip.kind == "链接" { return CGSize(width: min(650, maxWidth), height: 490) }
        return CGSize(width: min(650, maxWidth), height: 440)
    }
}

/// Full-resolution picture for the preview, without zoom controls.
struct PreviewImage: View {
    let clip: Clip
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: clip.fingerprint) {
            let data = clip.parts.flatMap { $0 }.first { ["public.png", "public.tiff", "public.jpeg", "public.heic", "public.gif"].contains($0.type) }?.data
            image = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: data.flatMap { NSImage(data: $0) }) }
            }
        }
    }
}

struct FullItemPreview: View {
    @ObservedObject var store: Store
    let id: UUID
    var clip: Clip? { store.archive.clips.first { $0.id == id } }

    var body: some View {
        VStack(spacing: 0) {
            if let clip {
                header(clip)
                content(clip).padding(.horizontal, 12)
                footer(clip)
            } else {
                Text("该条目已删除").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ clip: Clip) -> some View {
        HStack(spacing: 12) {
            Button { Controller.shared.closePreview() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("关闭 · Esc").accessibilityLabel("关闭预览")
            Text(clip.cardTitle).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                .onTapGesture { Controller.shared.rename(clip) }.help("重命名 · ⌘R")
            Spacer(minLength: 8)
            if !store.archive.boards.isEmpty {
                Menu {
                    ForEach(store.archive.boards) { board in
                        Button((clip.boards.contains(board.id) ? "✓ " : "") + board.name) { store.pin(clip, to: board.id) }
                    }
                } label: {
                    Image(systemName: clip.boards.isEmpty ? "circle.dashed" : "circle.fill").font(.system(size: 17))
                }.menuStyle(.borderlessButton).fixedSize().help("收藏到")
            }
            shareButton(clip)
            if clip.kind == "图片" {
                Button("旋转") { Controller.shared.rotate(clip) }.controlSize(.large)
                Button("提取文字") { Controller.shared.extractText(clip) }.controlSize(.large)
            } else if clip.kind != "文件" {
                Button("编辑") { Controller.shared.edit(clip) }.controlSize(.large).help("编辑 · ⌘E")
            }
        }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    @ViewBuilder private func shareButton(_ clip: Clip) -> some View {
        let icon = Image(systemName: "square.and.arrow.up").font(.system(size: 16))
        if clip.kind == "链接", let url = URL(string: clip.text) { ShareLink(item: url) { icon }.buttonStyle(.plain) }
        else if clip.kind == "文件", let path = clip.text.components(separatedBy: "\n").first { ShareLink(item: URL(fileURLWithPath: path)) { icon }.buttonStyle(.plain) }
        else if clip.kind == "图片" { ImageShareButton(clip: clip) }
        else { ShareLink(item: clip.text) { icon }.buttonStyle(.plain) }
    }

    @ViewBuilder private func content(_ clip: Clip) -> some View {
        Group {
            if clip.kind == "链接", let url = URL(string: clip.text), LinkPreviewCache.allowed(url) { LinkBrowser(url: url) }
            else if clip.kind == "文件", let path = clip.text.components(separatedBy: "\n").first { SystemFilePreview(url: URL(fileURLWithPath: path)) }
            else if clip.kind == "图片" { PreviewImage(clip: clip) }
            else if let color = CapturedColor.parse(clip.text) {
                ZStack {
                    Color(nsColor: color.nsColor)
                    Text(color.hex).font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(nsColor: color.nsColor.isLight ? .black : .white))
                }
            }
            else if clip.kind == "文字", CodeSyntax.language(clip.text) != nil { FullCodePreview(text: clip.text) }
            else {
                RichTextView(text: pageText(clip), identity: clip.id.uuidString + clip.fingerprint, inset: NSSize(width: 26, height: 22))
                    .background(Color.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Rich clips keep their own typography (shown a little larger); plain text gets a readable document style.
    private func pageText(_ clip: Clip) -> NSAttributedString {
        if RichTextCache.hasRichPart(clip), CodeSyntax.language(clip.text) == nil {
            let rich = clip.attributedText
            if RichTextCache.hasVisibleFormatting(rich) { return RichTextRendering.prepare(rich, scale: 1.3) }
        }
        return RichTextRendering.plain(clip.text, size: 16)
    }

    private func footer(_ clip: Clip) -> some View {
        HStack(spacing: 8) {
            Group {
                if clip.kind == "图片" { Text(PreviewMetadata.imageSize(clip).map { "\($0.width) × \($0.height)" } ?? "图片") }
                else if clip.kind == "链接" { Text(clip.text).lineLimit(1).truncationMode(.middle) }
                else if clip.kind == "文件" { Text(clip.text.components(separatedBy: "\n").first ?? clip.text).lineLimit(1).truncationMode(.middle) }
                else if let summary = PreviewMetadata.colorSummary(hex: clip.text) { Text(summary) }
                else { Text(PreviewMetadata.textSummary(clip.text)) }
            }.font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
            if clip.kind == "链接" || clip.kind == "文件" {
                Button(clip.kind == "链接" ? "在浏览器中打开" : "打开文件") { Controller.shared.openItem(clip) }.controlSize(.regular)
            }
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }
}

private extension NSColor {
    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return true }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.6
    }
}

/// Share button for pictures: the image is decoded when the preview appears.
struct ImageShareButton: View {
    let clip: Clip
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                ShareLink(item: Image(nsImage: image), preview: SharePreview("图片", image: Image(nsImage: image))) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 16))
                }.buttonStyle(.plain)
            } else {
                Image(systemName: "square.and.arrow.up").font(.system(size: 16)).foregroundStyle(.tertiary)
            }
        }
        .task(id: clip.fingerprint) {
            let data = clip.parts.flatMap { $0 }.first { ["public.png", "public.tiff", "public.jpeg", "public.heic", "public.gif"].contains($0.type) }?.data
            image = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: data.flatMap { NSImage(data: $0) }) }
            }
        }
    }
}
