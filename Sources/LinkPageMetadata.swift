import AppKit
import LinkPresentation

/// Fallback for pages LinkPresentation cannot read in time: bilibili answers its
/// WebKit loader with HTTP 412, WeChat articles often take 15–20 s. The page's
/// Open Graph tags are read directly, first as a link-preview crawler (what
/// bilibili serves), then as Safari (what WeChat serves).
enum LinkPageMetadata {
    static let userAgents = [
        "facebookexternalhit/1.1 Facebot Twitterbot/1.0",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    ]
    static let maxPageBytes = 1024 * 1024
    static let maxImageBytes = 8 * 1024 * 1024

    struct Page: Equatable {
        var title: String?
        var siteName: String?
        var image: URL?
        /// The document's own `<title>`, whitespace folded; not a preview title by itself (see `previewTitle`).
        var documentTitle: String? = nil
        /// The Open Graph title, else the `<title>` unless it reads like a block or error page.
        var previewTitle: String? { title ?? documentTitle.flatMap { LinkPageMetadata.isBlockPageTitle($0) ? nil : $0 } }
    }

    /// Titles of anti-bot, block and error pages: not worth showing as a preview.
    static func isBlockPageTitle(_ title: String) -> Bool {
        let text = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".…!！")))
        if text.isEmpty { return true }
        // A whole title, or a phrase followed by a separator ("Attention Required! | Cloudflare"); not "Access control lists".
        let phrases = ["forbidden", "not found", "error", "oops", "403", "404", "denied", "unauthorized", "blocked", "just a moment", "attention required", "access denied",
                       "page not found", "checking your browser", "verify you are human", "are you a robot", "are you human", "security check", "robot check", "too many requests",
                       "service unavailable", "bad gateway", "gateway timeout", "something went wrong", "please wait", "request blocked", "ddos protection",
                       "this site can’t be reached", "this site can't be reached"]
        // Only a bar, dash or dot separates a site name from the phrase; a colon starts real text ("Not Found: a novel").
        let separators = CharacterSet(charactersIn: "|-–—·•")
        for phrase in phrases where text.hasPrefix(phrase) {
            let rest = text.dropFirst(phrase.count).trimmingCharacters(in: CharacterSet(charactersIn: " !！.…"))
            if rest.isEmpty || rest.unicodeScalars.first.map(separators.contains) == true { return true }
        }
        // Chinese titles have no separators; these openings are specific enough to match as prefixes.
        let chinese = ["未知错误", "出错啦", "出错了", "访问受限", "访问异常", "页面不存在", "页面找不到", "无法访问", "禁止访问", "请稍候", "请稍后", "安全验证", "人机验证", "验证失败", "参数错误", "链接已失效", "内容不存在"]
        if chinese.contains(where: { text.hasPrefix($0) }) { return true }
        // Titles that begin with a status code: "404 Not Found", "Error 503", "403 - Forbidden".
        return text.range(of: #"^(error\s*)?(4\d\d|5\d\d)\b"#, options: .regularExpression) != nil
    }

    /// Host as Messages shows it (`mp.weixin.qq.com` → `weixin.qq.com`, `www.bbc.co.uk` → `bbc.co.uk`).
    /// LinkPresentation's own presentation transformer computes it; when that private
    /// class is unavailable, fall back to dropping `www.`/`m.`/`mobile.` prefixes.
    static func displayHost(_ url: URL) -> String {
        let key = (url.host ?? "").lowercased()
        hostLock.lock(); let cached = hostCache[key]; hostLock.unlock()
        if let cached { return cached }
        let value = onMain { computeDisplayHost(url) }
        hostLock.lock(); if hostCache.count > 500 { hostCache.removeAll() }; hostCache[key] = value; hostLock.unlock()
        return value
    }
    private static let hostLock = NSLock()
    private static var hostCache: [String: String] = [:]
    private static func computeDisplayHost(_ url: URL) -> String {
        if let type = NSClassFromString("LPLinkMetadataPresentationTransformer") as? NSObject.Type,
           type.instancesRespond(to: NSSelectorFromString("setMetadata:")),
           type.instancesRespond(to: NSSelectorFromString("setURL:")),
           type.instancesRespond(to: NSSelectorFromString("domainName")) {
            let metadata = LPLinkMetadata(); metadata.originalURL = url; metadata.url = url
            let transformer = type.init()
            transformer.setValue(metadata, forKey: "metadata"); transformer.setValue(url, forKey: "URL")
            if let name = transformer.value(forKey: "domainName") as? String, !name.isEmpty { return name }
        }
        var host = (url.host ?? "").lowercased()
        while let prefix = ["www.", "m.", "mobile."].first(where: { host.hasPrefix($0) && host.dropFirst($0.count).contains(".") }) { host.removeFirst(prefix.count) }
        return host
    }

    /// LinkPresentation's dominant image background colour (the Messages bubble colour) for
    /// metadata it fetched itself. Returns nil if the private class is unavailable.
    static func bubbleColor(metadata: LPLinkMetadata, url: URL) -> NSColor? {
        onMain { transformerBubbleColor(metadata: metadata, url: url) }
    }
    /// LinkPresentation's private classes are UI-side; they are only used on the main thread.
    private static func onMain<T>(_ work: () -> T) -> T { Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work) }
    private static func transformerBubbleColor(metadata: LPLinkMetadata, url: URL) -> NSColor? {
        guard let transformerType = NSClassFromString("LPLinkMetadataPresentationTransformer") as? NSObject.Type,
              transformerType.instancesRespond(to: NSSelectorFromString("setMetadata:")),
              transformerType.instancesRespond(to: NSSelectorFromString("setURL:")),
              transformerType.instancesRespond(to: NSSelectorFromString("presentationProperties")) else { return nil }
        let transformer = transformerType.init()
        transformer.setValue(metadata, forKey: "metadata"); transformer.setValue(url, forKey: "URL")
        guard let properties = transformer.value(forKey: "presentationProperties") as? NSObject,
              properties.responds(to: NSSelectorFromString("dominantImageBackgroundColor")) else { return nil }
        return properties.value(forKey: "dominantImageBackgroundColor") as? NSColor
    }

    /// Same colour for an image fetched outside LinkPresentation (wrapped as an LPImage);
    /// falls back to the image's average colour.
    static func bubbleColor(for image: NSImage, url: URL) -> NSColor? {
        precondition(!Thread.isMainThread, "Dominant colour is computed off the UI thread")
        return systemBubbleColor(for: image, url: url) ?? averageColor(image)
    }

    static func systemBubbleColor(for image: NSImage, url: URL) -> NSColor? {
        onMain { lpImageBubbleColor(for: image, url: url) }
    }
    private static func lpImageBubbleColor(for image: NSImage, url: URL) -> NSColor? {
        let initializer = NSSelectorFromString("initWithPlatformImage:")
        if let imageType = NSClassFromString("LPImage") as? NSObject.Type, imageType.instancesRespond(to: initializer),
           let allocated = imageType.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
           // `init…` consumes the allocated instance and returns a +1 reference.
           let lpImage = allocated.perform(initializer, with: image)?.takeRetainedValue() {
            let metadata = LPLinkMetadata(); metadata.originalURL = url; metadata.url = url; metadata.title = " "
            if metadata.responds(to: NSSelectorFromString("setImage:")) {
                metadata.setValue(lpImage, forKey: "image")
                return transformerBubbleColor(metadata: metadata, url: url)
            }
        }
        return nil
    }

    static func averageColor(_ image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    static func isDark(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.55
    }

    static func isYouTube(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"].contains(host)
    }

    private static let metaTag = try! NSRegularExpression(pattern: "<meta\\b[^<>]{0,4096}>", options: [.caseInsensitive])
    private static let metaAttribute = try! NSRegularExpression(pattern: "([a-zA-Z:_-]+)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')", options: [])
    static func parse(_ html: String, base: URL) -> Page {
        let head = html.range(of: "</head>", options: .caseInsensitive).map { String(html[..<$0.lowerBound]) } ?? html
        var meta: [String: String] = [:]
        let tag = Self.metaTag, attribute = Self.metaAttribute
        let ns = head as NSString
        for match in tag.matches(in: head, range: NSRange(location: 0, length: ns.length)) {
            let text = ns.substring(with: match.range) as NSString
            var attributes: [String: String] = [:]
            for pair in attribute.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                let name = text.substring(with: pair.range(at: 1)).lowercased()
                let valueRange = pair.range(at: 3).location != NSNotFound ? pair.range(at: 3) : pair.range(at: 4)
                attributes[name] = text.substring(with: valueRange)
            }
            guard let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"])?.lowercased(),
                  let content = attributes["content"], meta[key] == nil else { continue }
            let value = decodeEntities(content).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { meta[key] = value }
        }
        // `title` is only the Open Graph / Twitter / meta-name title; a bare <title> is `documentTitle` and
        // becomes a preview title through `previewTitle`, which leaves out block and error pages.
        let title = meta["og:title"] ?? meta["twitter:title"] ?? meta["title"]
        let imageText = meta["og:image:secure_url"] ?? meta["og:image"] ?? meta["og:image:url"] ?? meta["twitter:image"] ?? meta["twitter:image:src"]
        let image = imageText.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }.flatMap { LinkPreviewPolicy.canLoad($0) ? $0 : nil }
        return Page(title: title, siteName: meta["og:site_name"], image: image, documentTitle: documentTitle(in: head))
    }

    private static let documentTitleTag = try! NSRegularExpression(pattern: "<title\\b[^>]{0,200}>([^<]{0,1024})</title\\s*>", options: [.caseInsensitive])
    private static func documentTitle(in head: String) -> String? {
        let ns = head as NSString
        guard let match = documentTitleTag.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let folded = decodeEntities(ns.substring(with: match.range(at: 1))).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return folded.isEmpty ? nil : folded
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        var output = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            output += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let name = String(after[..<semi])
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") { replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else if name.hasPrefix("#") { replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else { replacement = named[name.lowercased()] }
                if let replacement { output += replacement; rest = after[after.index(after: semi)...]; continue }
            }
            output += "&"; rest = after
        }
        return output + rest
    }

    /// HTML text: the header's charset, else the page's own `<meta charset>` / `http-equiv`
    /// declaration, else UTF-8. Undecodable bytes give nil (never a lossy, garbled title).
    static func decodeHTML(_ data: Data, headerEncoding: String.Encoding?) -> String? {
        if let headerEncoding { return String(data: data, encoding: headerEncoding) }
        let prefix = String(decoding: data.prefix(4096), as: UTF8.self)
        if let match = prefix.range(of: #"charset\s*=\s*["']?([A-Za-z0-9_\-]+)"#, options: [.regularExpression, .caseInsensitive]) {
            let name = prefix[match].replacingOccurrences(of: #"(?i)charset\s*=\s*["']?"#, with: "", options: .regularExpression)
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId { return String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) }
        }
        return String(data: data, encoding: .utf8)
    }

    /// The page's title only (no image), as the link-preview crawler sees it.
    static func title(of url: URL, request: PreviewRequest, completion: @escaping (String?) -> Void) {
        let page = LimitedFetch(url: url, userAgent: userAgents[0], limit: maxPageBytes, accept: { $0.hasPrefix("text/html") }, allowed: LinkPreviewPolicy.automaticResolved) { data, finalURL, encoding in
            guard let data, let finalURL, let html = decodeHTML(data, headerEncoding: encoding) else { completion(nil); return }
            completion(parse(html, base: finalURL).title)
        }
        request.add { page.cancel() }
        page.start()
    }

    /// Fetches the page and its preview image, trying each user agent in turn.
    /// `allowed` is checked for every page redirect. Image URLs come from the page and
    /// usually carry hash-like names, so they only need a public host (never an intranet or IP).
    static func load(_ url: URL, allowed: @escaping (URL) -> Bool, request: PreviewRequest, agents: ArraySlice<String> = ArraySlice(userAgents), fallback: (page: Page, url: URL, agent: String)? = nil, completion: @escaping (LinkPreviewResult?) -> Void) {
        // Every agent is tried for an Open Graph title first; the page's own <title> is the last resort.
        guard let agent = agents.first, !request.cancelled else {
            if let fallback, !request.cancelled { deliver(fallback.page, finalURL: fallback.url, agent: fallback.agent, request: request, completion: completion) } else { completion(nil) }
            return
        }
        // `found` is the <title> of a page that had no Open Graph title; the first one found is the one kept.
        let next: ((page: Page, url: URL, agent: String)?) -> Void = { found in
            load(url, allowed: allowed, request: request, agents: agents.dropFirst(), fallback: fallback ?? found, completion: completion)
        }
        // The entry address is checked like every redirect (a name can resolve to a local address); DNS blocks, so not here.
        DispatchQueue.global(qos: .utility).async {
            guard !request.cancelled, allowed(url) else { completion(nil); return }
            fetchPage(url, agent: agent, allowed: allowed, request: request, next: next, completion: completion)
        }
    }

    private static func fetchPage(_ url: URL, agent: String, allowed: @escaping (URL) -> Bool, request: PreviewRequest, next: @escaping ((page: Page, url: URL, agent: String)?) -> Void, completion: @escaping (LinkPreviewResult?) -> Void) {
        let page = LimitedFetch(url: url, userAgent: agent, limit: maxPageBytes, accept: { $0.hasPrefix("text/html") || $0.hasPrefix("application/xhtml") }, allowed: allowed) { data, finalURL, encoding in
            guard !request.cancelled else { return }
            guard let data, let finalURL, let html = decodeHTML(data, headerEncoding: encoding) else { next(nil); return }
            let parsed = parse(html, base: finalURL)
            guard parsed.title != nil else { next(parsed.previewTitle == nil ? nil : (parsed, finalURL, agent)); return }
            deliver(parsed, finalURL: finalURL, agent: agent, request: request, completion: completion)
        }
        request.add { page.cancel() }
        page.start()
    }

    /// The preview for a parsed page: its title, and its image when there is a public one.
    private static func deliver(_ parsed: Page, finalURL: URL, agent: String, request: PreviewRequest, completion: @escaping (LinkPreviewResult?) -> Void) {
        guard let title = parsed.previewTitle else { completion(nil); return }
        let subtitle = displayHost(finalURL)
        guard let imageURL = parsed.image, LinkPreviewPolicy.publicAddress(imageURL) else { completion(LinkPreviewResult(title: title, subtitle: subtitle)); return }
        let image = LimitedFetch(url: imageURL, userAgent: agent, limit: maxImageBytes, accept: { $0.hasPrefix("image/") }, allowed: LinkPreviewPolicy.publicAddress) { data, _, _ in
            guard !request.cancelled else { return }
            let bounded = data.flatMap { previewThumbnail(from: $0) }
            completion(LinkPreviewResult(title: title, subtitle: subtitle, image: bounded, background: bounded.flatMap { bubbleColor(for: $0, url: finalURL) }, backdrop: bounded.map(frostedBackdrop)))
        }
        request.add { image.cancel() }
        image.start()
    }
}

func boundedPreviewImage(_ source: NSImage) -> NSImage {
    let size = source.size; let ratio = min(1, 600 / max(1, max(size.width, size.height)))
    let output = NSImage(size: NSSize(width: size.width * ratio, height: size.height * ratio))
    output.lockFocus(); source.draw(in: NSRect(origin: .zero, size: output.size)); output.unlockFocus(); return output
}

/// One cookie-less GET with a byte cap and a per-redirect URL check.
private final class LimitedFetch: NSObject, URLSessionDataDelegate {
    private let url: URL
    private let userAgent: String
    private let limit: Int
    private let accept: (String) -> Bool
    private let allowed: (URL) -> Bool
    private var completion: ((Data?, URL?, String.Encoding?) -> Void)?
    private var data = Data()
    private var finalURL: URL?
    private var encoding: String.Encoding?
    private var session: URLSession?
    private let lock = NSLock()

    init(url: URL, userAgent: String, limit: Int, accept: @escaping (String) -> Bool, allowed: @escaping (URL) -> Bool, completion: @escaping (Data?, URL?, String.Encoding?) -> Void) {
        self.url = url; self.userAgent = userAgent; self.limit = limit; self.accept = accept; self.allowed = allowed; self.completion = completion
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        lock.lock(); self.session = session; lock.unlock()
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        session.dataTask(with: request).resume()
    }

    func cancel() { finish(nil) }

    private func finish(_ result: Data?) {
        lock.lock()
        let completion = self.completion; self.completion = nil
        let session = self.session; self.session = nil
        let finalURL = self.finalURL, encoding = self.encoding
        lock.unlock()
        session?.invalidateAndCancel()
        completion?(result, finalURL, encoding)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let next = request.url, LinkPreviewPolicy.canLoad(next), allowed(next) else { completionHandler(nil); finish(nil); return }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), accept((response.mimeType ?? "").lowercased()),
              response.expectedContentLength <= Int64(limit) else { completionHandler(.cancel); finish(nil); return }
        lock.lock()
        finalURL = response.url
        if let name = response.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId { encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock(); data.append(chunk); let over = data.count > limit; let snapshot = over ? data.prefix(limit) : nil; lock.unlock()
        // HTML metadata lives in <head>; keep what we have instead of failing on large pages.
        if let snapshot { finish(accept("text/html") ? Data(snapshot) : nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let body = data; lock.unlock()
        finish(error == nil ? body : nil)
    }
}
