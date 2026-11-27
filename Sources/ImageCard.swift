import AppKit
import SwiftUI
import ImageIO

/// How an image card scales its picture, by aspect ratio: when the image's
/// aspect ratio is close enough to the area's, fill and crop; otherwise fit the whole image.
enum ImageCardScaling {
    /// Similarity from which the image fills the area.
    static let fillRatio = 0.8
    static func fills(image: CGSize, area: CGSize, ratio: Double = fillRatio) -> Bool {
        guard image.width > 0, image.height > 0, area.width > 0, area.height > 0 else { return false }
        let imageAspect = Double(image.width / image.height), areaAspect = Double(area.width / area.height)
        let similarity = 1 - abs(imageAspect - areaAspect) / max(imageAspect, areaAspect)
        return ratio <= similarity
    }
}

/// Body of an image card, checkerboard, adaptively scaled image,
/// and a capsule with the pixel size centred in the footer row.
struct ImageCardBody: View {
    let clip: Clip
    var compact = false
    var indexLabel: String? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var loaded = false
    @State private var pixels: String?
    @State private var requestedVersion = ""
    private static var sizeLabels: [String: String] = [:]
    private var version: String { clip.fingerprint }
    static func sizeLabel(width: Int, height: Int) -> String { "\(width) × \(height)" }
    private func load() {
        let requested = version, key = clip.id.uuidString + ":" + requested, clip = clip
        requestedVersion = requested; image = nil; loaded = false; pixels = Self.sizeLabels[key]
        PreviewCache.shared.load(clip) { result in
            guard requestedVersion == requested else { return }
            image = result; loaded = true
        }
        guard pixels == nil else { return }
        PreviewCache.shared.queue.async {
            let label = PreviewMetadata.imageSize(clip).map { Self.sizeLabel(width: $0.width, height: $0.height) }
            DispatchQueue.main.async {
                guard let label else { return }
                if Self.sizeLabels.count > 2000 { Self.sizeLabels.removeAll() }
                Self.sizeLabels[key] = label
                if requestedVersion == requested { pixels = label }
            }
        }
    }
    private func capsule(_ text: String) -> some View {
        Text(text).font(.callout).monospacedDigit()
            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.55) : Color.black.opacity(0.5))
            .padding(.horizontal, 6).frame(height: 18)
            .background { CardLabelBackdrop().clipShape(RoundedRectangle(cornerRadius: 9, style: .circular)) }
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Checkerboard()
                if let image {
                    let fills = ImageCardScaling.fills(image: image.size, area: geometry.size)
                    Image(nsImage: image).resizable().aspectRatio(contentMode: fills ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                else if loaded { Label("无法预览图片", systemImage: "photo").font(.caption).foregroundStyle(.secondary) }
                else { ProgressView().controlSize(.small) }
            }
        }
        .overlay(alignment: .bottom) { if !compact, let pixels { capsule(pixels).padding(.bottom, 8) } }
        .overlay(alignment: .bottomTrailing) { if let indexLabel { ShortcutBadge(label: indexLabel).padding(.trailing, 8).padding(.bottom, 8) } }
        .onAppear { if requestedVersion != version { load() } }
        .onChange(of: version) { _, _ in load() }
    }
}
