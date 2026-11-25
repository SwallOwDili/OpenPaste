import AppKit
import SwiftUI

struct RichLinkCard: View {
    let clip: Clip
    let enabled: Bool
    let store: Store
    var indexLabel: String? = nil
    /// Tap on the title: the card decides (rename when already the only selection, else select).
    var titleTap: () -> Void = {}
    @Binding var cover: Bool
    /// A preview bubble is drawn (with or without an image): it runs to the card's bottom edge with the
    /// index in its caption, so the card leaves out its own footer.
    var bubble: Binding<Bool> = .constant(false)
    var headerHeight: CGFloat = 0
    @State var result: LinkPreviewResult?
    @State var finished = false
    @State private var userRequested = false
    private var needsExplicitLoad: Bool {
        guard let url = URL(string: clip.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return LinkPreviewPolicy.canLoad(url) && !LinkPreviewPolicy.automatic(url)
    }
    var body: some View {
        Group {
            if let result { LinkBubble(result: result, title: clip.userLabel ?? result.title, indexLabel: indexLabel, topInset: cover ? headerHeight : 0, rename: titleTap) }
            else { placeholder.padding(12) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { reload() }
        .onChange(of: result?.image != nil, initial: true) { _, full in cover = full }
        .onChange(of: result != nil, initial: true) { _, shown in bubble.wrappedValue = shown }
        .onDisappear { cover = false; bubble.wrappedValue = false }
        .onChange(of: enabled) { _, _ in userRequested = false; reload() }
        .onChange(of: clip.text) { _, _ in userRequested = false; result = nil; reload() }
    }
    /// Loading, failed, disabled and map states keep the original card layout.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = result?.image { Image(nsImage: image).resizable().scaledToFill().frame(maxWidth: .infinity, minHeight: 28, maxHeight: .infinity).clipped().layoutPriority(-1) }
            else if !finished && enabled { ProgressView("加载预览…").font(.caption).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if MapLink.parse(clip.text) != nil { Image(systemName: "map").font(.system(size: 30)).foregroundStyle(.green) }
            Text(clip.userLabel ?? result?.title ?? MapLink.parse(clip.text)?.name ?? clip.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).onTapGesture(perform: titleTap)
            Text(result?.subtitle ?? MapLink.parse(clip.text)?.coordinate ?? URL(string: clip.text).map(LinkPageMetadata.displayHost) ?? clip.text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if enabled && needsExplicitLoad && !userRequested {
                Button("点击加载预览") { userRequested = true; reload(userInitiated: true) }
                    .buttonStyle(.borderless).font(.system(size: 11))
                    .help("此链接可能属于内网或携带验证信息。点击会访问原网址。")
            } else if finished && result == nil {
                Text(enabled ? "预览不可用 · 原链接仍可使用" : "联网预览已关闭").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if result?.image == nil { Spacer(minLength: 0) }
        }
    }
    func reload(userInitiated: Bool = false) {
        guard enabled else { result = nil; finished = true; return }
        finished = false
        LinkPreviewCache.shared.load(clip.text, userInitiated: userInitiated) { preview in
            guard store.networkPreviews else { result = nil; finished = true; return }
            result = preview; finished = true
            if preview == nil { userRequested = false }
            if let preview { store.applyLinkPreview(preview, to: clip) }
        }
    }
}

/// Link preview bubble. Colours and the domain follow Messages (LinkPresentation's dominant
/// image colour, its simplified host). The caption is two single lines pinned to the bottom:
/// title, then link, on the solid bubble colour. The image is shown whole: when it is tall enough
/// to fill the cover area it fills it; otherwise a frosted (blurred, tinted) copy fills the rest.
struct LinkBubble: View {
    let result: LinkPreviewResult
    let title: String
    var indexLabel: String? = nil
    /// Height of the card header drawn over the cover.
    var topInset: CGFloat = 0
    let rename: () -> Void
    static let defaultBackground = NSColor(srgbRed: 230 / 255, green: 230 / 255, blue: 230 / 255, alpha: 1)
    /// LPLinkView's background for Apple Maps links.
    static let mapBackground = NSColor(srgbRed: 229 / 255, green: 230 / 255, blue: 233 / 255, alpha: 1)
    static let captionHeight: CGFloat = 50
    var body: some View {
        let background = result.background ?? Self.defaultBackground
        let dark = LinkPageMetadata.isDark(background)
        let primary = dark ? Color.white : Color.black.opacity(0.88)
        let secondary = dark ? Color.white.opacity(0.62) : Color.black.opacity(0.48)
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let cover = max(0, height - Self.captionHeight)
            ZStack(alignment: .top) {
                Color(nsColor: background)
                if let image = result.image {
                    let natural = width * image.size.height / max(1, image.size.width)
                    let full = natural >= cover
                    let sharp = full ? cover : natural
                    // Always below the header, so the header never sits on the image's own text; an image
                    // too tall for the space left runs under the caption rather than up.
                    let top = full ? 0 : min(topInset, max(0, height - sharp))
                    // Frosted fill only where the image leaves space; a pre-shrunk copy enlarged is already
                    // soft, so nothing is blurred while the strip animates.
                    if !full {
                        Image(nsImage: result.backdrop ?? image).resizable().interpolation(.high).scaledToFill()
                            .frame(width: width, height: height).clipped()
                            .overlay(Color(nsColor: background).opacity(0.45))
                    }
                    Image(nsImage: image).resizable().scaledToFill().frame(width: width, height: sharp).clipped()
                        .offset(y: top)
                    if topInset > 0 {
                        LinearGradient(stops: [.init(color: .black.opacity(0.5), location: 0), .init(color: .black.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
                            .frame(height: topInset + 12)
                    }
                }
                caption(primary: primary, secondary: secondary)
                    .frame(width: width, height: Self.captionHeight)
                    // Solid and square, like the Messages caption bar. An explicit Rectangle: a bare
                    // `.background(Color)` fills the card's container shape (its 12 pt rounded rect),
                    // which turned the caption into a rounded pill floating on the image.
                    .background { Rectangle().fill(Color(nsColor: background)) }
                    .offset(y: height - Self.captionHeight)
            }
            .frame(width: width, height: height, alignment: .top)
        }
    }
    private func caption(primary: Color, secondary: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(result.videoTitle ?? title)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(primary)
                .lineLimit(1).truncationMode(.tail)
                .onTapGesture(perform: rename)
            HStack(spacing: 5) {
                if let icon = result.icon, result.videoTitle != nil {
                    Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().frame(width: 13, height: 13).clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text(result.videoTitle == nil ? result.subtitle : title + " · " + result.subtitle)
                    .font(.system(size: 11.5)).foregroundStyle(secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if let indexLabel { Text(indexLabel).font(.system(size: 10)).foregroundStyle(secondary) }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}
