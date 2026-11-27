import AppKit
import SwiftUI

/// Dominant colour of an app icon, used to tint a card's header.
enum IconAccent {
    /// Fixed header colours for well-known apps, keyed by bundle ID.
    /// Looked up before analysing the icon, so e.g. Notes gets its yellow instead of a darker sampled tone.
    static let known: [String: UInt32] = [
        "com.adobe.Acrobat": 0x9B0A00, "com.adobe.AfterEffects": 0x3B3B92, "com.adobe.Dreamweaver": 0x285C28,
        "com.adobe.flash": 0x901313, "com.adobe.Fonts": 0x34363A, "com.adobe.illustrator": 0xE58B00,
        "com.adobe.InDesign": 0xC0264D, "com.adobe.Lean": 0x74528F, "com.adobe.Photoshop": 0x005C90,
        "com.adobe.RoboHelp": 0x0A957C, "com.adobe.XD": 0x85156B, "com.agilebits.onepassword7": 0x299DE6,
        "com.apple.AddressBook": 0xA9A799, "com.apple.AppStore": 0x0088FF, "com.apple.calculator": 0x8E8E93,
        "com.apple.dt.Xcode": 0x0088FF, "com.apple.finder": 0x0088FF, "com.apple.iCal": 0xFF383C,
        "com.apple.iBooksX": 0xFF8D28, "com.apple.iWork.Keynote": 0x02B1F7, "com.apple.iWork.Numbers": 0x6ABC26,
        "com.apple.iWork.Pages": 0xEA6E27, "com.apple.mail": 0x0088FF, "com.apple.Photos": 0xFF383C,
        "com.apple.reminders": 0xFF383C, "com.apple.Safari": 0x0088FF, "com.apple.Terminal": 0x313233,
        "com.apple.TextEdit": 0x8E8E93, "com.bohemiancoding.sketch3": 0xFF8D00, "com.figma.Desktop": 0x0088FF,
        "com.framer.electron": 0x2983DA, "com.google.Chrome": 0x1A74E8, "com.linear": 0x313233,
        "com.microsoft.Excel": 0x107C41, "com.microsoft.onenote.mac": 0x963CBA, "com.microsoft.Outlook": 0x0078D4,
        "com.microsoft.Powerpoint": 0xCF4D2B, "com.microsoft.teams": 0x4650C2, "com.microsoft.Word": 0x185ABD,
        "com.microsoft.VSCode": 0x0D76BD, "com.tinyspeck.slackmacgap": 0x611F69, "notion.id": 0x313233,
        "ru.keepcoder.Telegram": 0x04A1DD, "com.tdesktop.Telegram": 0x04A1DD, "com.apple.TV": 0x313233,
        "com.apple.clock": 0x313233, "com.apple.Dictionary": 0xD43B45, "com.apple.FaceTime": 0x34C759,
        "com.apple.findmy": 0x34C759, "com.apple.freeform": 0x04B5C8, "com.apple.games": 0xFF383C,
        "com.apple.Home": 0xFF8D28, "com.apple.IconComposer": 0x313233, "com.apple.iMovieApp": 0x5027CB,
        "com.apple.journal": 0x25283D, "com.apple.Maps": 0x34C759, "com.apple.MobileSMS": 0x34C759,
        "com.apple.Notes": 0xFAB700, "com.apple.Passwords": 0x313233, "com.apple.PhotoBooth": 0xFF383C,
        "com.apple.podcasts": 0xCB30E0, "com.apple.Preview": 0x0088FF, "com.apple.QuickTimePlayerX": 0x0088FF,
        "com.apple.SFSymbols": 0x313233, "com.apple.shortcuts": 0x3E38A3, "com.apple.Stickies": 0xF2B600,
        "com.apple.stocks": 0x313233, "com.apple.TestFlight": 0x0088FF, "com.apple.helpviewer": 0xFF8D28,
        "com.apple.VoiceMemos": 0x313233, "com.apple.weather": 0x2889F1, "com.openai.chat": 0x313233,
        "com.openai.codex": 0x313233, "com.anthropic.claudefordesktop": 0xD65C38, "pl.maketheweb.cleanshotx": 0x0088FF,
        "com.facebook.Origami-Studio": 0x0088FF, "net.whatsapp.WhatsApp": 0x16D95C, "com.sublimetext.4": 0xFF8D28,
        "ai.perplexity.macv3": 0x313233
    ]
    static func knownColor(_ bundleID: String) -> NSColor? {
        known[bundleID].map { NSColor(srgbRed: CGFloat(($0 >> 16) & 0xFF) / 255, green: CGFloat(($0 >> 8) & 0xFF) / 255, blue: CGFloat($0 & 0xFF) / 255, alpha: 1) }
    }
    /// Picks the most prominent saturated colour; near-white tiles and transparent corners are ignored.
    static func dominant(of image: NSImage) -> NSColor? {
        let side = 40
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .medium
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        struct Bucket { var weight = 0.0; var r = 0.0, g = 0.0, b = 0.0, count = 0.0 }
        var buckets: [Int: Bucket] = [:]
        var fallback = Bucket()
        for y in 0..<side { for x in 0..<side {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.6 else { continue }
            let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
            let high = max(r, g, b), low = min(r, g, b)
            let saturation = high == 0 ? 0 : (high - low) / high
            fallback.r += r; fallback.g += g; fallback.b += b; fallback.count += 1
            if high > 0.93 && saturation < 0.12 { continue }
            if high < 0.08 { continue }
            let key = Int(r * 7.99) << 6 | Int(g * 7.99) << 3 | Int(b * 7.99)
            var bucket = buckets[key] ?? Bucket()
            bucket.weight += 0.3 + saturation; bucket.r += r; bucket.g += g; bucket.b += b; bucket.count += 1
            buckets[key] = bucket
        } }
        let chosen = buckets.values.max { $0.weight < $1.weight } ?? fallback
        guard chosen.count > 0 else { return nil }
        var color = NSColor(srgbRed: chosen.r / chosen.count, green: chosen.g / chosen.count, blue: chosen.b / chosen.count, alpha: 1)
        // The header carries white text, so very light colours are darkened until it stays readable.
        if let c = color.usingColorSpace(.sRGB) {
            let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
            if luminance > 0.62 { let k = 0.62 / luminance; color = NSColor(srgbRed: c.redComponent * k, green: c.greenComponent * k, blue: c.blueComponent * k, alpha: 1) }
        }
        return color
    }
}

extension PreviewCache {
    private static var accents: [String: NSColor] = [:]
    private static var missingAccents = Set<String>()
    /// Header colour for a source application, cached per bundle identifier.
    func accentColor(_ bundleID: String, store: AccentStore = .shared) -> NSColor? {
        if let cached = Self.accents[bundleID] { return cached }
        if let known = IconAccent.knownColor(bundleID) { Self.accents[bundleID] = known; return known }
        guard !Self.missingAccents.contains(bundleID) else { return nil }
        let stamp = AccentStore.stamp(for: bundleID)
        if let stamp, let saved = store.color(for: bundleID, stamp: stamp) { Self.accents[bundleID] = saved; return saved }
        let finishTiming = AcceptanceMetrics.begin("preview.icon.accent"); defer { finishTiming() }
        guard let icon = sourceIcon(bundleID), let color = IconAccent.dominant(of: icon) else { Self.missingAccents.insert(bundleID); return nil }
        Self.accents[bundleID] = color
        if let stamp { store.set(color, for: bundleID, stamp: stamp) }
        return color
    }
}

/// Header colours persisted per source app, so a restart
/// reuses them instead of analysing every icon again. Main thread only; writes go to a background queue.
final class AccentStore {
    static let shared = AccentStore(url: try? AppEnvironment.current.validateCacheRoot(
        AppEnvironment.current.previewCacheRoot.deletingLastPathComponent().appendingPathComponent("AppAccents.json")))
    /// Bump when `IconAccent.dominant` changes so saved colours are recomputed.
    static let algorithmVersion = 1
    static let capacity = 300
    struct Entry: Codable, Equatable { var stamp: String; var rgb: [Double]; var used: Date }
    private(set) var entries: [String: Entry] = [:]
    let url: URL?
    private let queue = DispatchQueue(label: "openpaste.accent-store", qos: .utility)
    private var saveScheduled = false
    private let saveDelay: TimeInterval

    init(url: URL?, saveDelay: TimeInterval = 1) {
        self.url = url
        self.saveDelay = saveDelay
        if let url, let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded.filter { $0.value.rgb.count == 3 }
        }
    }

    /// Identifies the icon a colour was computed from: algorithm, app location, build number and Info.plist date.
    static func stamp(for bundleID: String) -> String? {
        guard !bundleID.isEmpty else { return nil }
        let appURL = bundleID == Bundle.main.bundleIdentifier ? Bundle.main.bundleURL : NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        guard let appURL else { return nil }
        let info = appURL.appendingPathComponent("Contents/Info.plist")
        let modified = (try? info.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let build = (NSDictionary(contentsOf: info)?["CFBundleVersion"] as? String) ?? ""
        return "\(algorithmVersion)|\(appURL.path)|\(build)|\(Int(modified))"
    }

    func color(for bundleID: String, stamp: String) -> NSColor? {
        guard var entry = entries[bundleID], entry.stamp == stamp else { return nil }
        if Date().timeIntervalSince(entry.used) > 86400 { entry.used = Date(); entries[bundleID] = entry; scheduleSave() }
        return NSColor(srgbRed: entry.rgb[0], green: entry.rgb[1], blue: entry.rgb[2], alpha: 1)
    }

    func set(_ color: NSColor, for bundleID: String, stamp: String) {
        guard let c = color.usingColorSpace(.sRGB) else { return }
        entries[bundleID] = Entry(stamp: stamp, rgb: [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)], used: Date())
        if entries.count > Self.capacity {
            for key in entries.sorted(by: { $0.value.used < $1.value.used }).prefix(entries.count - Self.capacity).map(\.key) { entries[key] = nil }
        }
        scheduleSave()
    }

    private func scheduleSave() {
        guard url != nil, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay) { [weak self] in self?.flush() }
    }

    /// Writes the current entries atomically off the main thread; `completion` runs on the main thread.
    func flush(completion: (() -> Void)? = nil) {
        saveScheduled = false
        guard let url, let data = try? JSONEncoder().encode(entries) else { completion?(); return }
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            DispatchQueue.main.async { completion?() }
        }
    }
}
