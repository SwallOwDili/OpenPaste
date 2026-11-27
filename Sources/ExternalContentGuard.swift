import AppKit
import Foundation
import ImageIO

/// Which addresses a public web page may resolve to.
enum PublicAddress {
    /// True when `host` resolves, and every address it resolves to is a public one.
    /// Blocking (getaddrinfo): call from a background queue. Results are kept for five minutes.
    static func isPublic(host: String) -> Bool {
        let key = host.lowercased()
        cacheLock.lock()
        if let hit = cache[key], Date().timeIntervalSince(hit.date) < 300 { cacheLock.unlock(); return hit.value }
        cacheLock.unlock()
        let value = resolve(key)
        cacheLock.lock()
        if cache.count > 500 { cache.removeAll() }
        cache[key] = (value, Date())
        cacheLock.unlock()
        return value
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: (value: Bool, date: Date)] = [:]

    private static func resolve(_ host: String) -> Bool {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(list) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var any = false
        while let entry = cursor?.pointee {
            any = true
            guard let address = entry.ai_addr else { return false }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
                if !isPublicIPv4(bytes) { return false }
            case AF_INET6:
                let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
                if !isPublicIPv6(bytes) { return false }
            default: return false
            }
            cursor = entry.ai_next
        }
        return any
    }

    static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1], b[2]) {
        case (0, _, _), (10, _, _), (127, _, _): return false              // this network, private, loopback
        case (100, 64...127, _): return false                              // carrier-grade NAT
        case (169, 254, _): return false                                   // link local
        case (172, 16...31, _), (192, 168, _): return false                // private
        case (192, 0, 0), (192, 0, 2), (198, 51, 100), (203, 0, 113): return false  // protocol and documentation
        // 198.18.0.0/15 is not blocked: proxy tools that answer DNS themselves (Clash, Surge) hand out these addresses.
        case (224..., _, _): return false                                  // multicast, reserved, broadcast
        default: return true
        }
    }

    static func isPublicIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b.allSatisfy({ $0 == 0 }) { return false }                                                  // ::
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return false }                            // ::1
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { return isPublicIPv4(Array(b[12..<16])) }  // IPv4-mapped
        if b[0] & 0xFE == 0xFC { return false }                                                        // fc00::/7 unique local
        if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return false }                                        // fe80::/10 link local
        if b[0] == 0xFF { return false }                                                               // multicast
        return true
    }

    /// Any numeric spelling of an IPv4 address (`127.1`, `0x7f.0.0.1`, `2130706433`, `0177.0.0.1`) or an IPv6 literal.
    static func isNumericHost(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_aton(host, &v4) != 0 || inet_pton(AF_INET6, host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), &v6) == 1
    }
}

/// Imports clipboard HTML without letting the importer touch the network.
///
/// The system HTML importer fetches style sheets, images and CSS background images while it parses
/// (the rendering is the request), whatever the web-preview setting says. Everything that can load
/// something is removed first; the import itself runs on the caller's queue, so callers keep it off the main thread.
enum HTMLImport {
    private static let options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
    private static let removals: [(NSRegularExpression, String)] = [
        (#"<(script|iframe|object|embed|video|audio|canvas|noscript|picture)\b.*?</\1\s*>"#, ""),
        (#"<(script|iframe|object|embed|video|audio|canvas|noscript|picture|img|image|use|link|source|track|base|input|frame|param)\b[^>]*>"#, ""),
        (#"<meta\b[^>]*http-equiv[^>]*>"#, ""),
        (#"\sbackground\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, ""),
        (#"@import\s+[^;{]*;?"#, ""),
        (#"@font-face\s*\{[^}]*\}"#, ""),
        (#"image-set\([^)]*\)"#, "none"),
        (#"url\(\s*[^)]*\)"#, "none"),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: options), $0.1) }

    /// The HTML as UTF-8 text with everything that loads a resource removed.
    static func sanitized(_ data: Data) -> String {
        let text: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let utf16 = String(data: data, encoding: .utf16) { text = utf16 }
        else { text = String(decoding: data, as: UTF8.self) }
        var result = text
        for (expression, template) in removals {
            result = expression.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: template)
        }
        return result
    }

    static func attributedString(from data: Data) -> NSAttributedString? {
        try? NSAttributedString(data: Data(sanitized(data).utf8),
                                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                                documentAttributes: nil)
    }
}

/// Preview image from encoded data: the header is read first, and a picture over `pixelLimit` is refused
/// (a small file can claim billions of pixels). The system scaler then decodes straight down to `maxPixel`
/// instead of building the full-size bitmap first.
func previewThumbnail(from data: Data, maxPixel: Int = 600, pixelLimit: Int = 64_000_000) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0, width * height <= pixelLimit else { return nil }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                    kCGImageSourceThumbnailMaxPixelSize: maxPixel]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
}
