import AppKit
import SwiftUI

extension Clip {
    /// A single-file clip without a user label: its header may say “音频” once the file reads as audio.
    var showsAudioTitle: Bool {
        kind == "文件" && !text.contains("\n") && (userLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What an audio card shows, read once per file in the background and kept in memory.
struct AudioCardInfo {
    /// The file was found and read as audio (the card is then titled “音频”).
    var parsed = false
    var title: String
    var detail: String?
    var cover: NSImage?
}

@MainActor
final class AudioCardCache {
    static let shared = AudioCardCache()
    private var entries: [String: AudioCardInfo] = [:]
    private var waiting: [String: [(AudioCardInfo) -> Void]] = [:]

    func cached(_ path: String) -> AudioCardInfo? { entries[path] }

    func load(_ path: String, completion: @escaping (AudioCardInfo) -> Void) {
        if let entry = entries[path] { completion(entry); return }
        if waiting[path] != nil { waiting[path]?.append(completion); return }
        waiting[path] = [completion]
        Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: path)
            // A missing file or an unmounted volume: just the name, no tags.
            let info: AudioInfo? = FileManager.default.fileExists(atPath: path) ? await AudioInfo.load(url, duration: false) : nil
            let card = AudioCardInfo(parsed: info != nil, title: info?.title ?? url.deletingPathExtension().lastPathComponent,
                                     detail: info?.detail,
                                     cover: info?.artwork.flatMap(NSImage.init(data:)).map(boundedCover))
            await MainActor.run {
                if self.entries.count >= 500 { self.entries.removeAll() }
                self.entries[path] = card
                let callbacks = self.waiting.removeValue(forKey: path) ?? []
                callbacks.forEach { $0(card) }
            }
        }
    }
}

/// Cover art shrunk for a card (decoding a multi-megabyte picture on every redraw would stall the strip).
private func boundedCover(_ image: NSImage) -> NSImage {
    let side: CGFloat = 160, scale = min(1, side / max(1, max(image.size.width, image.size.height)))
    let size = NSSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context; context.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: size)); NSGraphicsContext.restoreGraphicsState()
    let output = NSImage(size: size); output.addRepresentation(rep); return output
}

/// Card body for a single audio file, centred: a soft wash of the cover's
/// colours, the cover with a shadow, then title, artist · album and the path.
struct AudioCardBody: View {
    let path: String
    var compact = false
    /// Drawn inside the body so the colour wash runs to the card's bottom edge (no footer strip).
    var indexLabel: String? = nil
    /// Set once the file has been read as audio, so the card header can say “音频”.
    var parsed: Binding<Bool> = .constant(false)
    let rename: () -> Void
    @State private var info: AudioCardInfo?

    var body: some View {
        let title = info?.title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let colors = AudioPreview.palette(for: title)
        GeometryReader { geometry in
            // Text below the cover takes about 58 pt (44 without the path); the cover gets the rest.
            let textHeight: CGFloat = compact ? 40 : 58
            let side = max(44, min(86, geometry.size.height - textHeight - 22))
            VStack(spacing: 0) {
                Spacer(minLength: 8)
                cover(colors).frame(width: side, height: side)
                Spacer(minLength: 8)
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    .onTapGesture(perform: rename)
                if let detail = info?.detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).padding(.top, 2)
                }
                if !compact {
                    // Kept clear of the index in the bottom-right corner.
                    Text(path).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).padding(.top, 5).padding(.horizontal, indexLabel == nil ? 0 : 10)
                }
                Spacer(minLength: 6)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .overlay(alignment: .bottomTrailing) {
            if let indexLabel { ShortcutBadge(label: indexLabel).padding(.trailing, 8).padding(.bottom, 8) }
        }
        .background {
            LinearGradient(colors: [colors.0.opacity(0.16), colors.1.opacity(0.06)], startPoint: .top, endPoint: .bottom)
        }
        .onAppear {
            if let cached = AudioCardCache.shared.cached(path) { info = cached; parsed.wrappedValue = cached.parsed }
            else { AudioCardCache.shared.load(path) { info = $0; parsed.wrappedValue = $0.parsed } }
        }
    }

    @ViewBuilder private func cover(_ colors: (Color, Color)) -> some View {
        Group {
            if let cover = info?.cover { Image(nsImage: cover).resizable().scaledToFill() }
            else {
                ZStack {
                    LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: 34, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.black.opacity(0.06), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
    }
}
