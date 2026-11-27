import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Playback for the preview: never starts on its own, and is torn down when the preview goes away.
@MainActor
final class AudioPlayerModel: ObservableObject {
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var failed = false
    var scrubbing = false
    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    let url: URL

    init(url: URL) { self.url = url }

    private func prepare() -> AVPlayer {
        if let player { return player }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                if let total = player.currentItem?.duration.seconds, total.isFinite, total > 0 { self.duration = total }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playing = false; self?.player?.seek(to: .zero); self?.position = 0 }
        }
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor in if failed { self?.failed = true; self?.playing = false } }
        }
        self.player = player
        return player
    }

    func toggle() {
        guard !failed else { return }
        let player = prepare()
        if playing { player.pause() } else { player.play() }
        playing.toggle()
    }

    func seek(to seconds: Double) {
        position = seconds
        prepare().seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player?.pause(); playing = false
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()
        observer = nil; endObserver = nil; statusObservation = nil; player = nil
    }
}

struct AudioPreview: View {
    let url: URL
    @StateObject private var model: AudioPlayerModel
    @State private var info: AudioInfo?
    @State private var artwork: NSImage?

    init(url: URL) {
        self.url = url
        _model = StateObject(wrappedValue: AudioPlayerModel(url: url))
    }

    /// A soft two-colour gradient picked from the title, so each song keeps its own colours.
    static func palette(for title: String) -> (Color, Color) {
        let hues: [(Double, Double)] = [(0.95, 0.80), (0.58, 0.70), (0.08, 0.98), (0.45, 0.55), (0.75, 0.88), (0.12, 0.03)]
        let index = Int(title.unicodeScalars.reduce(UInt32(0)) { ($0 &* 31) &+ $1.value } % UInt32(hues.count))
        let (a, b) = hues[index]
        return (Color(hue: a, saturation: 0.45, brightness: 0.85), Color(hue: b, saturation: 0.55, brightness: 0.55))
    }

    var body: some View {
        let title = info?.title ?? url.deletingPathExtension().lastPathComponent
        let colors = Self.palette(for: title)
        HStack(spacing: 28) {
            cover(colors).frame(width: 200, height: 200)
            details(title: title)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A background, not a ZStack layer: a scaled-to-fill cover must not size the preview
        // (it pushed the header and footer out of the popover).
        .background { background(colors) }
        .clipped()
        .task(id: url) {
            let loaded = await Task.detached(priority: .userInitiated) { await AudioInfo.load(url) }.value
            info = loaded
            artwork = loaded.artwork.flatMap(NSImage.init(data:))
        }
        .onDisappear { model.stop() }
    }

    private func details(title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 24, weight: .bold)).lineLimit(2)
            if let line = info?.detail {
                Text(line).font(.system(size: 15, weight: .medium)).opacity(0.85).lineLimit(1)
            }
            Text([info?.format ?? url.pathExtension.uppercased(), info?.duration.map(Self.clock)].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12, weight: .medium)).opacity(0.65)
            Spacer(minLength: 12)
            controls
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: 200, alignment: .leading)
    }

    @ViewBuilder private func background(_ colors: (Color, Color)) -> some View {
        if let artwork {
            Image(nsImage: artwork).resizable().scaledToFill().blur(radius: 40, opaque: true).overlay(Color.black.opacity(0.35))
        } else {
            LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    @ViewBuilder private func cover(_ colors: (Color, Color)) -> some View {
        Group {
            if let artwork { Image(nsImage: artwork).resizable().scaledToFill() }
            else {
                ZStack {
                    LinearGradient(colors: [colors.0.opacity(0.9), colors.1], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note").font(.system(size: 72, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private var controls: some View {
        let total = model.duration > 0 ? model.duration : (info?.duration ?? 0)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Button { model.toggle() } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(.black.opacity(0.8))
                        .frame(width: 48, height: 48).background(Circle().fill(.white))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                }
                .buttonStyle(.plain).disabled(model.failed).help(model.playing ? "暂停" : "播放")
                if model.failed { Text("无法播放此文件").font(.system(size: 12)).opacity(0.8) }
            }
            Slider(value: Binding(get: { min(model.position, max(total, 0.01)) }, set: { model.position = $0 }), in: 0...max(total, 0.01)) { editing in
                model.scrubbing = editing
                if !editing { model.seek(to: model.position) }
            }
            .controlSize(.small).tint(.white).disabled(total <= 0 || model.failed)
            HStack {
                Text(Self.clock(model.position)); Spacer(); Text("-" + Self.clock(max(0, total - model.position)))
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit()).opacity(0.7)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
}
