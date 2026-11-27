import AppKit
import SwiftUI

/// Body of a file card, laid out as: the icon or thumbnail on top (10 below the header,
/// 12 at the sides, bottom-aligned), then 12 pt down a centred two-line name in the secondary colour that keeps its tail.
struct FileCardBody: View {
    let clip: Clip
    let compact: Bool
    var rename: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "heic", "gif", "webp"]
    private static let icons = NSCache<NSString, NSImage>()
    static func paths(_ clip: Clip) -> [String] { clip.text.components(separatedBy: "\n").filter { !$0.isEmpty } }
    /// A single image file shows its own picture; anything else shows an icon.
    static func showsThumbnail(_ paths: [String]) -> Bool {
        paths.count == 1 && imageExtensions.contains(URL(fileURLWithPath: paths[0]).pathExtension.lowercased())
    }
    static func icon(_ paths: [String]) -> NSImage {
        guard paths.count == 1, let path = paths.first else { return NSImage(named: NSImage.multipleDocumentsName) ?? NSImage() }
        if let cached = icons.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons.setObject(icon, forKey: path as NSString)
        return icon
    }
    var body: some View {
        let paths = Self.paths(clip)
        VStack(spacing: 12) {
            Group {
                if Self.showsThumbnail(paths) { ClipThumbnail(clip: clip, alignment: .bottom) }
                else { Image(nsImage: Self.icon(paths)).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom) }
            }
            Text(clip.title).font(.system(size: 12)).multilineTextAlignment(.center).lineLimit(compact ? 1 : 2).truncationMode(.head)
                .foregroundStyle(Color(nsColor: RichTextRendering.footerColor(onDark: colorScheme == .dark)))
                .frame(maxWidth: .infinity).help(clip.title).onTapGesture(perform: rename)
        }
        .padding(.top, 10).padding(.horizontal, 12).padding(.bottom, 4)
    }
}
