import AppKit
import SwiftUI
import ImageIO

// Main-thread cache ownership; expensive decoding happens on the preview queue.
final class PreviewCache {
    static let shared = PreviewCache()
    let images = NSCache<NSString, NSImage>()
    let icons = NSCache<NSString, NSImage>()
    var pending: [UUID: [(NSImage?) -> Void]] = [:]
    var missingIcons = Set<String>()
    let queue = DispatchQueue(label: "openpaste.previews", qos: .userInitiated)
    private(set) var decodeCount = 0
    init() { images.countLimit = 100; images.totalCostLimit = 32 * 1024 * 1024; icons.countLimit = 100 }
    func load(_ clip: Clip, completion: @escaping (NSImage?) -> Void) {
        let key = clip.id.uuidString as NSString
        if let image = images.object(forKey: key) { completion(image); return }
        if pending[clip.id] != nil { pending[clip.id]?.append(completion); return }
        let data = clip.parts.lazy.flatMap { $0 }.first { ["public.png", "public.tiff", "public.jpeg", "public.gif", "com.compuserve.gif", "public.heic", "com.microsoft.bmp"].contains($0.type) }?.data
        let fileURL = clip.kind == "文件" ? clip.text.components(separatedBy: "\n").first.map { URL(fileURLWithPath: $0) } : nil
        guard data != nil || fileURL != nil else { completion(nil); return }
        pending[clip.id] = [completion]
        let id = clip.id
        decodeCount += 1
        queue.async {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 600, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
            let source = data.map { CGImageSourceCreateWithData($0 as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) } ?? fileURL.map { CGImageSourceCreateWithURL($0 as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) }
            let resolvedSource = source ?? nil
            let cg = resolvedSource.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
            DispatchQueue.main.async {
                let image = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                if let image = image, let cg = cg { self.images.setObject(image, forKey: key, cost: cg.width * cg.height * 4) }
                let callbacks = self.pending.removeValue(forKey: id) ?? []
                callbacks.forEach { $0(image) }
            }
        }
    }
    func sourceIcon(_ bundleID: String) -> NSImage? {
        if bundleID == Bundle.main.bundleIdentifier, let url = Bundle.main.url(forResource: "OpenPaste-v2", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            icons.setObject(icon, forKey: bundleID as NSString)
            return icon
        }
        guard !bundleID.isEmpty, !missingIcons.contains(bundleID) else { return nil }
        if let icon = icons.object(forKey: bundleID as NSString) { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { missingIcons.insert(bundleID); return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons.setObject(icon, forKey: bundleID as NSString)
        return icon
    }
}

struct ClipThumbnail: View {
    let clip: Clip
    @State private var image: NSImage?
    @State private var loaded = false
    var body: some View {
        Group {
            if let image = image { Image(nsImage: image).resizable().scaledToFit() }
            else if loaded { Label("无法预览图片", systemImage: "photo").font(.caption).foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { guard !loaded else { return }; PreviewCache.shared.load(clip) { image = $0; loaded = true } }
    }
}
