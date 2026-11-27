import AppKit
import CoreLocation

/// Address line for a map card, as Messages lists it: largest first for Chinese, Japanese and
/// Korean ("东京 千代田区 千代田 · 日本"), smallest first otherwise; no street, no repeats.
func mapAddress(_ placemark: CLPlacemark) -> String? {
    mapAddress(subLocality: placemark.subLocality, locality: placemark.locality, area: placemark.administrativeArea, country: placemark.country,
               language: Locale.preferredLanguages.first ?? "zh-Hans")
}

func mapAddress(subLocality: String?, locality: String?, area: String?, country: String?, language: String) -> String? {
    let largestFirst = ["zh", "ja", "ko"].contains(where: { language.hasPrefix($0) })
    var parts: [String] = []
    for part in (largestFirst ? [area, locality, subLocality] : [subLocality, locality, area]).compactMap({ $0 }) where !part.isEmpty && !parts.contains(part) { parts.append(part) }
    let place = parts.joined(separator: largestFirst ? " " : ", ")
    let line = [place, country ?? ""].filter { !$0.isEmpty && !(parts.contains($0) && $0 == country) }.joined(separator: " · ")
    return line.isEmpty ? nil : line
}

/// The Maps balloon Messages draws: a red gradient disc with a white rim and pin glyph, a small
/// dot on the exact spot, and the place name below with a white halo. Draws into the focused image.
func drawMapMarker(at point: NSPoint, name: String) {
    NSGraphicsContext.saveGraphicsState()
    let dot = NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
    NSColor.white.setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
    NSColor(srgbRed: 0.86, green: 0.13, blue: 0.24, alpha: 1).setFill(); NSBezierPath(ovalIn: dot).fill()
    let disc = NSRect(x: point.x - 15, y: point.y + 5, width: 30, height: 30)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.set()
    NSColor.white.setFill(); NSBezierPath(ovalIn: disc).fill()
    NSShadow().set()
    NSGradient(starting: NSColor(srgbRed: 0.96, green: 0.33, blue: 0.42, alpha: 1), ending: NSColor(srgbRed: 0.78, green: 0.09, blue: 0.22, alpha: 1))?
        .draw(in: NSBezierPath(ovalIn: disc.insetBy(dx: 2, dy: 2)), angle: -90)
    if let glyph = NSImage(systemSymbolName: "mappin", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .bold).applying(.init(paletteColors: [.white]))) {
        glyph.draw(in: NSRect(x: disc.midX - glyph.size.width / 2, y: disc.midY - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height))
    }
    let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    let halo = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: NSColor.white, .strokeColor: NSColor.white, .strokeWidth: -6])
    let text = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(0.85)])
    let size = text.size()
    let origin = NSPoint(x: point.x - min(size.width, 280) / 2, y: point.y - 5 - size.height)
    let rect = NSRect(origin: origin, size: NSSize(width: min(size.width, 280), height: size.height))
    halo.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]); text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    NSGraphicsContext.restoreGraphicsState()
}

/// A 24 px wide copy of a cover image; enlarged, it is the frosted fill without a live blur.
func frostedBackdrop(_ image: NSImage) -> NSImage {
    let width: CGFloat = 24, height = max(1, (width * image.size.height / max(1, image.size.width)).rounded())
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    let output = NSImage(size: NSSize(width: width, height: height)); output.addRepresentation(rep)
    return output
}
