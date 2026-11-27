import AppKit

func runLinkPreviewBoundaryTests() {
    var checks = 0
    func check(_ value: @autoclosure () throws -> Bool, _ name: String) {
        do { guard try value() else { print("FAIL: \(name)"); exit(1) }; checks += 1 }
        catch { print("FAIL: \(name): \(error)"); exit(1) }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenPaste-preview-boundary-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = LinkPreviewCache(root: root.appendingPathComponent("cache"))
    let manual = ["http://127.0.0.1/", "http://[::1]/", "https://router.lan/", "https://INTRANET.CORP./", "http://printer.local/", "https://a.internal/", "https://example.com/?code=once", "https://example.com/?token=x", "https://example.com/redeem/once", "https://example.com/unsubscribe/x", "https://example.com/#credential", "https://example.com/?session_id=x"]
    for text in manual {
        let url = URL(string: text)!
        check(!LinkPreviewPolicy.automatic(url) && LinkPreviewPolicy.canLoad(url), "suspect URL requires explicit request")
        var called = false
        cache.load(text) { result in called = true; check(result == nil, "automatic suspect preview returns no result") }
        check(called && cache.requests.isEmpty && cache.jobs.isEmpty && cache.active == 0, "blocked preview never schedules networking or cache work")
    }
    for text in ["https://www.apple.com/mac/", "https://github.com/SwallOwDili/OpenPaste", "https://maps.apple.com/?q=Coffee&ll=37.7,-122.4", "https://example.com/article?id=123"] {
        check(LinkPreviewPolicy.automatic(URL(string: text)!), "ordinary public URLs remain eligible")
    }
    for text in ["file:///tmp/a", "https://user:password@example.com/", "javascript:alert(1)"] {
        check(!LinkPreviewPolicy.canLoad(URL(string: text)!), "unsafe URL forms cannot be fetched even manually")
    }
    do {
        let base = URL(string: "https://www.bilibili.com/video/BV1Nyx764EMy/")!
        let html = """
        <html><head><title>出错啦!</title>
        <meta data-vue-meta="true" property="og:title" content="Claude背后的Anthropic：掌握核心科技的邪教_哔哩哔哩_bilibili">
        <meta property='og:site_name' content='哔哩哔哩'>
        <meta property="og:image" content="//i0.hdslb.com/bfs/archive/a.jpg@1200w_630h">
        <meta property="og:title" content="second title ignored">
        </head><body><meta property="og:image" content="https://evil.example/late.jpg"></body></html>
        """
        let page = LinkPageMetadata.parse(html, base: base)
        check(page.title == "Claude背后的Anthropic：掌握核心科技的邪教_哔哩哔哩_bilibili", "og:title wins over <title> and later duplicates")
        check(page.siteName == "哔哩哔哩", "single-quoted attributes parse")
        check(page.image?.absoluteString == "https://i0.hdslb.com/bfs/archive/a.jpg@1200w_630h", "protocol-relative og:image resolves against the page")
        let entities = LinkPageMetadata.parse(#"<meta name="twitter:title" content="A &amp; B &quot;C&quot; &#x4E2D;&#25991; &bogus; &"><meta property="og:image" content="/img.png"><meta property="og:image:secure_url" content="javascript:alert(1)">"#, base: base)
        check(entities.title == "A & B \"C\" 中文 &bogus; &", "HTML entities decode, unknown ones stay literal")
        check(entities.image == nil, "unsafe secure_url image is rejected rather than replaced")
        check(LinkPageMetadata.parse("<title>未知错误</title>", base: base).title == nil, "a bare <title> is not an Open Graph title")
        check(LinkPageMetadata.parse("<title>未知错误</title>", base: base).previewTitle == nil, "an error page's <title> is not a preview title")
        // The page's own <title> is the last resort for sites without Open Graph tags; block and error pages are left out.
        func previewTitle(_ html: String) -> String? { LinkPageMetadata.parse(html, base: base).previewTitle }
        check(previewTitle("<title>  Example\n   Domain &amp; more </title>") == "Example Domain & more", "a plain <title> becomes the preview title, whitespace folded and entities decoded")
        check(previewTitle(#"<title>Page one</title><meta property="og:title" content="Open Graph wins">"#) == "Open Graph wins", "the Open Graph title still wins over <title>")
        for blocked in ["Just a moment...", "Attention Required! | Cloudflare", "Access denied", "Page not found · GitHub · GitHub", "404 Not Found", "Error 503", "403 - Forbidden", "Forbidden",
                        "Too many requests", "Verify you are human", "Service Unavailable", "未知错误", "出错啦!", "访问受限", "页面不存在", "请稍候…", "安全验证", "", "   "] {
            check(previewTitle("<title>\(blocked)</title>") == nil, "block or error title is not used: \(blocked)")
        }
        for fine in ["Error handling in Go", "Not Found: a novel", "How to fix a 404 error", "Access control lists explained", "Just a moment of reflection", "验证码识别原理", "Apple Developer Documentation"] {
            check(previewTitle("<title>\(fine)</title>") == fine, "an ordinary title is kept: \(fine)")
        }
        check(previewTitle("<title>" + String(repeating: "a", count: 3000) + "</title>") == nil, "an oversized <title> is ignored rather than cut")
        check(LinkPageMetadata.parse(#"<meta property="og:image" content="/a/b.png"><meta property="og:title" content=" T ">"#, base: base) == LinkPageMetadata.Page(title: "T", siteName: nil, image: URL(string: "https://www.bilibili.com/a/b.png")), "relative image and trimmed title")
        for (host, shown) in [("www.youtube.com", "youtube.com"), ("www.bilibili.com", "bilibili.com"), ("mp.weixin.qq.com", "weixin.qq.com"), ("www.bbc.co.uk", "bbc.co.uk"), ("space.bilibili.com", "space.bilibili.com")] {
            check(LinkPageMetadata.displayHost(URL(string: "https://\(host)/x")!) == shown, "display host matches Messages: \(host)")
        }
        check(LinkPageMetadata.parse(#"<title>当我拿到iPhone Duo… - YouTube</title><meta name="title" content="当我拿到iPhone Duo…">"#, base: base).title == "当我拿到iPhone Duo…", "meta name=title is a page title; <title> with the site suffix is not")
        check(LinkPageMetadata.parse(#"<title> - YouTube</title><meta name="title" content=""><meta property="og:title" content="">"#, base: base).title == nil, "an empty, script-rendered page has no title")
        check(mapAddress(subLocality: "千代田", locality: "千代田区", area: "东京", country: "日本", language: "zh-Hans-CN") == "东京 千代田区 千代田 · 日本", "Chinese map address runs largest first")
        check(mapAddress(subLocality: "Embarcadero", locality: "San Francisco", area: "CA", country: "United States", language: "en-US") == "Embarcadero, San Francisco, CA · United States", "English map address runs smallest first")
        check(mapAddress(subLocality: nil, locality: "东京", area: "东京", country: nil, language: "zh-Hans") == "东京" && mapAddress(subLocality: nil, locality: nil, area: nil, country: nil, language: "zh") == nil, "map address drops repeats and empty parts")
        check(LinkPreviewPolicy.publicHost(URL(string: "https://mmbiz.qpic.cn/mmbiz_jpg/\(String(repeating: "a", count: 111))/0?wx_fmt=jpeg")!) && !LinkPreviewPolicy.automatic(URL(string: "https://mmbiz.qpic.cn/mmbiz_jpg/\(String(repeating: "a", count: 111))/0")!), "hash-named page images need only a public host")
        check(!LinkPreviewPolicy.publicHost(URL(string: "http://192.168.1.1/a.png")!) && !LinkPreviewPolicy.publicHost(URL(string: "https://nas.local/a.png")!) && !LinkPreviewPolicy.publicHost(URL(string: "file:///tmp/a.png")!), "page images never reach private hosts")
        check(LinkPageMetadata.isYouTube(URL(string: "https://www.youtube.com/watch?v=x")!) && LinkPageMetadata.isYouTube(URL(string: "https://youtu.be/x")!) && !LinkPageMetadata.isYouTube(URL(string: "https://notyoutube.com/x")!), "YouTube host detection is exact")
    }
    do {
        func solid(_ color: NSColor) -> NSImage { let image = NSImage(size: NSSize(width: 64, height: 36)); image.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 64, height: 36).fill(); image.unlockFocus(); return image }
        var colors: [NSColor?] = []
        // The private LinkPresentation calls hop to the main thread, so wait by running it, not blocking it.
        var finished = false
        func waitForBackground() { let deadline = Date().addingTimeInterval(5); while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }; finished = false }
        DispatchQueue.global().async {
            let url = URL(string: "https://www.youtube.com/watch?v=x")!
            colors = [LinkPageMetadata.bubbleColor(for: solid(NSColor(srgbRed: 0.4, green: 0.3, blue: 0.17, alpha: 1)), url: url), LinkPageMetadata.bubbleColor(for: solid(NSColor(srgbRed: 0.95, green: 0.9, blue: 0.82, alpha: 1)), url: url)]
            DispatchQueue.main.async { finished = true }
        }
        waitForBackground()
        check(colors.allSatisfy { $0 != nil }, "bubble colour is computed off the main thread")
        if NSClassFromString("LPImage") != nil {
            // A thumbnail-sized image (LinkPresentation skips tiny ones) must get the system colour, not the average fallback.
            let split = NSImage(size: NSSize(width: 600, height: 315)); split.lockFocus()
            NSColor.brown.setFill(); NSRect(x: 0, y: 0, width: 600, height: 160).fill(); NSColor.white.setFill(); NSRect(x: 0, y: 160, width: 600, height: 155).fill(); split.unlockFocus()
            var dominant: NSColor?
            DispatchQueue.global().async { let value = LinkPageMetadata.systemBubbleColor(for: split, url: URL(string: "https://example.com/")!); DispatchQueue.main.async { dominant = value; finished = true } }
            waitForBackground()
            check(dominant != nil, "bubble colour comes from LinkPresentation, not the average fallback")
        }
        check(colors[0].map(LinkPageMetadata.isDark) == true && colors[1].map(LinkPageMetadata.isDark) == false, "dark bubbles get light text, light bubbles dark text")
        let backdrop = frostedBackdrop(solid(.systemTeal))
        check(backdrop.representations.first?.pixelsWide == 24 && backdrop.representations.first?.pixelsHigh == 14, "frosted fill is a 24 px copy, not a live blur")
    }
    do {
        // Charset: header first, then the page's own declaration; undecodable bytes are dropped, not garbled.
        let gbkName = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let gbk = String.Encoding(rawValue: gbkName)
        let page = #"<html><head><meta charset="gbk"><meta property="og:title" content="中文标题测试"></head>"#
        let data = page.data(using: gbk)!
        check(LinkPageMetadata.decodeHTML(data, headerEncoding: nil).map { LinkPageMetadata.parse($0, base: URL(string: "https://example.com/")!).title } == "中文标题测试", "a GBK page declared only in <meta charset> decodes")
        let equiv = #"<meta http-equiv="Content-Type" content="text/html; charset=GB2312"><meta property="og:title" content="中文">"#.data(using: gbk)!
        check(LinkPageMetadata.decodeHTML(equiv, headerEncoding: nil)?.contains("中文") == true, "http-equiv charset is honoured")
        check(LinkPageMetadata.decodeHTML(Data([0x3C, 0x61, 0xFF, 0xFE, 0x3E]), headerEncoding: nil) == nil, "undecodable bytes give no page rather than a garbled title")
        check(LinkPageMetadata.decodeHTML(Data("<a>标题</a>".utf8), headerEncoding: nil) == "<a>标题</a>", "UTF-8 without a declaration still decodes")
    }
    do {
        // Cover selection between LinkPresentation and the page fallback (no network: both loaders are fakes).
        let image = NSImage(size: NSSize(width: 4, height: 2))
        func run(system: LinkPreviewResult?, page: LinkPreviewResult?, pageAnswers: Bool = true) -> LinkPreviewResult?? {
            let web = LinkPreviewCache(root: root.appendingPathComponent("web-\(UUID())"))
            web.hedgeDelay = 0.02; web.fallbackGrace = 0.2; web.systemFetchAllowed = { _ in true }
            web.systemLoader = { _, _, done in DispatchQueue.global().async { done(system) } }
            web.pageLoader = { _, _, _, done in if pageAnswers { DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { done(page) } } }
            var outcome: LinkPreviewResult??
            web.loadWeb(URL(string: "https://example.com/a")!, userInitiated: false, request: PreviewRequest()) { outcome = .some($0) }
            let deadline = Date().addingTimeInterval(2)
            while outcome == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return outcome
        }
        let systemCover = LinkPreviewResult(title: "system", subtitle: "example.com", image: image)
        let systemBare = LinkPreviewResult(title: "system", subtitle: "example.com")
        let pageCover = LinkPreviewResult(title: "page", subtitle: "example.com", image: image)
        let pageBare = LinkPreviewResult(title: "page", subtitle: "example.com")
        check(run(system: systemCover, page: nil, pageAnswers: false)??.title == "system", "a LinkPresentation cover is used without waiting for the page")
        check(run(system: systemBare, page: pageCover)??.title == "page", "no LinkPresentation cover: the page's og:image is used")
        check(run(system: systemBare, page: nil).map { $0?.title } == "system" && run(system: systemBare, page: pageBare)??.image == nil, "neither has a cover: LinkPresentation's title, no image (never the site icon)")
        check(run(system: nil, page: pageBare)??.title == "page" && run(system: nil, page: nil).map { $0 == nil } == true, "LinkPresentation failure falls back to the page, then to no preview")
        check(run(system: systemBare, page: nil, pageAnswers: false)??.title == "system", "a page that never answers cannot hold back LinkPresentation's title past the grace period")
    }
    do {
        // Security: addresses, system fetch gate, HTML import, image size, page parsing.
        func address(_ text: String) -> Bool? {
            var v4 = in_addr(), v6 = in6_addr()
            if inet_pton(AF_INET, text, &v4) == 1 { return PublicAddress.isPublicIPv4(withUnsafeBytes(of: v4) { Array($0) }) }
            if inet_pton(AF_INET6, text, &v6) == 1 { return PublicAddress.isPublicIPv6(withUnsafeBytes(of: v6) { Array($0) }) }
            return nil
        }
        for blocked in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255",
                        "::", "::1", "fe80::1", "fd00::1", "fc00::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1"] {
            check(address(blocked) == false, "\(blocked) is not a public address")
        }
        for open in ["8.8.8.8", "1.1.1.1", "172.32.0.1", "100.63.255.255", "198.18.0.1", "2001:4860:4860::8888", "::ffff:8.8.8.8"] {
            check(address(open) == true, "\(open) is a public address")
        }
        check(!PublicAddress.isPublic(host: "localhost") && !PublicAddress.isPublic(host: "127.0.0.1") && !PublicAddress.isPublic(host: "no-such-host.invalid"), "a name resolving to loopback, a literal loopback and an unresolvable name are not public")
        check(PublicAddress.isPublic(host: "8.8.8.8"), "a public literal address resolves as public")
        for spelling in ["127.1", "0x7f.0.0.1", "2130706433", "0177.0.0.1", "::1", "[::1]", "192.168.1.1"] {
            check(PublicAddress.isNumericHost(spelling), "\(spelling) is a numeric host")
            check(!LinkPreviewPolicy.publicHost(URL(string: "http://\(spelling)/x") ?? URL(string: "http://invalid.example/")!) || URL(string: "http://\(spelling)/x") == nil, "\(spelling) is not a public host")
        }
        check(!PublicAddress.isNumericHost("example.com") && !PublicAddress.isNumericHost("1e100.net") && LinkPreviewPolicy.publicHost(URL(string: "https://example.com/a")!), "ordinary names stay public hosts")

        // The system fetch follows redirects unchecked: automatic previews use it only for listed sites.
        let gate = LinkPreviewCache(root: root.appendingPathComponent("gate-\(UUID())"))
        gate.hedgeDelay = 0.02; gate.fallbackGrace = 0.2
        var systemCalls = 0
        gate.systemLoader = { _, _, done in systemCalls += 1; done(nil) }
        gate.pageLoader = { _, _, _, done in DispatchQueue.global().async { done(LinkPreviewResult(title: "page", subtitle: "example.net")) } }
        func fetch(_ link: String, userInitiated: Bool) -> LinkPreviewResult? {
            var outcome: LinkPreviewResult??
            gate.loadWeb(URL(string: link)!, userInitiated: userInitiated, request: PreviewRequest()) { outcome = .some($0) }
            let deadline = Date().addingTimeInterval(2)
            while outcome == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return outcome ?? nil
        }
        check(fetch("https://blog.example.net/post", userInitiated: false)?.title == "page" && systemCalls == 0, "an automatic preview of another site never starts the system fetch")
        check(fetch("https://www.youtube.com/watch?v=abc", userInitiated: false) != nil && systemCalls == 1, "a listed site still uses the system fetch")
        check(fetch("https://blog.example.net/other", userInitiated: true) != nil && systemCalls == 2, "a link the user chose to load still uses the system fetch")
        check(!LinkPreviewPolicy.systemFetchAllowed(URL(string: "https://youtube.com.evil.example/")!) && !LinkPreviewPolicy.systemFetchAllowed(URL(string: "https://notyoutube.com/")!), "the list matches whole domain labels only")

        // Page parsing stays linear on unterminated tags.
        let started = Date()
        _ = LinkPageMetadata.parse(String(repeating: "<meta ", count: 170_000), base: URL(string: "https://example.com/")!)
        check(Date().timeIntervalSince(started) < 1, "1 MB of unterminated <meta tags parses in under a second")

        // Preview images: refuse huge claims, scale the rest while decoding.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 500, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let thumbnail = previewThumbnail(from: png)
        check(thumbnail?.size == NSSize(width: 600, height: 300), "a 1000x500 picture is scaled to 600x300 while decoding")
        check(previewThumbnail(from: png, pixelLimit: 100_000) == nil, "a picture over the pixel limit is refused")
        check(previewThumbnail(from: Data("not an image".utf8)) == nil, "undecodable data gives no image")

        // The page loader end to end, against a loopback server that answers by user agent.
        final class AgentServer {
            private var fd: Int32 = -1; private(set) var port: UInt16 = 0
            private let answer: (String) -> String
            init?(answer: @escaping (String) -> String) {
                self.answer = answer
                fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return nil }
                var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
                let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                guard bound == 0, listen(fd, 16) == 0 else { return nil }
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
                port = UInt16(bigEndian: addr.sin_port)
                let socketFD = fd
                // One thread per connection: URLSession may open an idle second connection that must not block the next request.
                Thread.detachNewThread { [answer] in
                    while true {
                        let client = accept(socketFD, nil, nil); if client < 0 { return }
                        Thread.detachNewThread {
                            var timeout = timeval(tv_sec: 3, tv_usec: 0)
                            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                            var buffer = [UInt8](repeating: 0, count: 8192)
                            let count = recv(client, &buffer, buffer.count, 0)
                            if count > 0 {
                                let request = String(decoding: buffer[0..<count], as: UTF8.self)
                                let agent = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("user-agent:") } ?? ""
                                let body = Array(answer(agent).utf8)
                                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                                _ = (Array(head.utf8) + body).withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
                            }
                            close(client)
                        }
                    }
                }
            }
            func stop() { shutdown(fd, SHUT_RDWR); close(fd) }
        }
        func loaded(_ html: @escaping (String) -> String) -> LinkPreviewResult? {
            guard let server = AgentServer(answer: html) else { print("FAIL: could not open a loopback server for the page loader check"); exit(1) }
            defer { server.stop() }
            // The loader hops to the main thread for the display host, so the main thread must keep running while waiting.
            var outcome: LinkPreviewResult??
            LinkPageMetadata.load(URL(string: "http://127.0.0.1:\(server.port)/page")!, allowed: { _ in true }, request: PreviewRequest()) { value in DispatchQueue.main.async { outcome = .some(value) } }
            let deadline = Date().addingTimeInterval(15)
            while outcome == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return outcome ?? nil
        }
        let crawler: (String) -> Bool = { $0.contains("facebookexternalhit") }
        check(loaded { _ in "<html><head><title>Plain site</title></head></html>" }?.title == "Plain site", "a site without Open Graph tags gets its <title>")
        check(loaded { crawler($0) ? "<html><head><title>Just a moment...</title></head></html>" : #"<html><head><title>x</title><meta property="og:title" content="Real title"></head></html>"# }?.title == "Real title",
              "a block page for the first agent does not stop the second agent's Open Graph title")
        check(loaded { crawler($0) ? "<html><head><title>First agent title</title></head></html>" : #"<html><head><meta property="og:title" content="Open Graph title"></head></html>"# }?.title == "Open Graph title",
              "an Open Graph title from a later agent beats the <title> of an earlier one")
        check(loaded { crawler($0) ? "<html><head><title>First agent title</title></head></html>" : "<html><head><title>Second agent title</title></head></html>" }?.title == "First agent title", "with no Open Graph title anywhere the first usable <title> is kept")
        check(loaded { _ in "<html><head><title>Access denied</title></head></html>" } == nil, "block page titles on every agent give no preview")

        // HTML import: the system importer loads whatever the markup points at; sanitized, it must not.
        final class Listener {
            private var fd: Int32 = -1; private(set) var port: UInt16 = 0
            private let lock = NSLock(); private var accepted = 0
            var count: Int { lock.lock(); defer { lock.unlock() }; return accepted }
            init?() {
                fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return nil }
                var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
                let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                guard bound == 0, listen(fd, 16) == 0 else { return nil }
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
                port = UInt16(bigEndian: addr.sin_port)
                let socketFD = fd
                Thread.detachNewThread { [self] in
                    while true { let client = accept(socketFD, nil, nil); if client < 0 { return }; close(client); lock.lock(); accepted += 1; lock.unlock() }
                }
            }
            func stop() { shutdown(fd, SHUT_RDWR); close(fd) }
        }
        if let listener = Listener() {
            let base = "http://127.0.0.1:\(listener.port)"
            let page = """
            <html><head><link rel="stylesheet" href="\(base)/a.css"><style>@import url(\(base)/b.css); p { background: url(\(base)/c.png); color: #c00 }</style></head>
            <body background="\(base)/d.png" style="background: url(\(base)/e.png)"><p>visible <b>text</b></p><img src="\(base)/f.png"><iframe src="\(base)/g.html"></iframe>
            <svg><image href="\(base)/h.png"/></svg><video poster="\(base)/i.png"></video></body></html>
            """
            _ = NSApplication.shared
            _ = NSAttributedString(html: Data(page.utf8), documentAttributes: nil)
            Thread.sleep(forTimeInterval: 0.5)
            check(listener.count > 0, "control: the system importer on raw HTML does contact the address in the markup")
            let before = listener.count
            let cleaned = HTMLImport.sanitized(Data(page.utf8))
            for fragment in ["<img", "<link", "<iframe", "<video", "<svg", "url(http", "@import", "background=", "127.0.0.1"] where fragment != "<svg" {
                check(!cleaned.lowercased().contains(fragment), "sanitized HTML has no \(fragment)")
            }
            var imported: NSAttributedString?
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { imported = HTMLImport.attributedString(from: Data(page.utf8)); finished.signal() }
            check(finished.wait(timeout: .now() + 20) == .success, "the sanitized import completes on a background queue")
            Thread.sleep(forTimeInterval: 0.5)
            check(listener.count == before, "the sanitized import makes no network request")
            check(imported?.string.contains("visible text") == true, "text survives the sanitizing")
            var bold = false
            imported?.enumerateAttribute(.font, in: NSRange(location: 0, length: imported?.length ?? 0)) { value, _, _ in if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) { bold = true } }
            check(bold, "bold survives the sanitizing")
            listener.stop()
        } else { print("FAIL: could not open a loopback listener for the HTML import check"); exit(1) }
    }
    do {
        // Copying a link again forgets what was kept for it: memory, failure cooldown and disk.
        let forgetting = LinkPreviewCache(root: root.appendingPathComponent("forget-\(UUID())"))
        let mine = "https://example.com/mine", other = "https://example.com/other"
        let json = forgetting.root.appendingPathComponent(forgetting.fileKey(mine)).appendingPathExtension("json")
        let otherJSON = forgetting.root.appendingPathComponent(forgetting.fileKey(other)).appendingPathExtension("json")
        try? FileManager.default.createDirectory(at: forgetting.root, withIntermediateDirectories: true)
        for url in [json, otherJSON] { try? Data("{\"title\":\"t\",\"subtitle\":\"s\"}".utf8).write(to: url) }
        for key in [mine, other] { forgetting.results[key] = LinkPreviewResult(title: "t", subtitle: "s"); forgetting.savedAt[key] = Date(); forgetting.failures[key] = Date() }
        forgetting.shortLived.insert(mine)
        forgetting.forget(" \(mine)\n")
        forgetting.diskQueue.sync {}
        check(forgetting.results[mine] == nil && forgetting.savedAt[mine] == nil && forgetting.failures[mine] == nil && !forgetting.shortLived.contains(mine), "forgetting a link clears its memory, failure cooldown and short-lived mark")
        check(!FileManager.default.fileExists(atPath: json.path), "forgetting a link removes its cache file")
        check(forgetting.results[other] != nil && forgetting.failures[other] != nil && FileManager.default.fileExists(atPath: otherJSON.path), "another link is left alone")

        // Deleting a link record forgets its preview; copying it again does not.
        do {
            let history = root.appendingPathComponent("history-delete-\(UUID())")
            func link(_ url: String) -> Clip { Clip(source: "Preview fixture", sourceID: "test.preview", kind: "链接", title: url, text: url, parts: [[ClipPart(type: "public.utf8-plain-text", data: Data(url.utf8))]]) }
            let deleted = link("https://example.com/deleted"), kept = link("https://example.com/kept")
            try HistoryStorage.write(Archive(clips: [deleted, kept]), to: history.appendingPathComponent("history.json"))
            let store = Store(root: history)
            let previews = LinkPreviewCache(root: root.appendingPathComponent("store-previews-\(UUID())"))
            store.linkPreviews = previews
            for url in ["https://example.com/deleted", "https://example.com/kept"] {
                previews.results[url] = LinkPreviewResult(title: "t", subtitle: "s"); previews.savedAt[url] = Date(); previews.failures[url] = Date()
            }
            store.enrichLink(kept)
            check(previews.results["https://example.com/kept"] != nil && previews.failures["https://example.com/kept"] != nil, "copying a link again does not clear its kept preview")
            store.delete(deleted.id)
            check(previews.results["https://example.com/deleted"] == nil && previews.failures["https://example.com/deleted"] == nil, "deleting a link record clears its kept preview")
            check(previews.results["https://example.com/kept"] != nil, "deleting one link leaves another link's preview")
            store.flush()
        } catch { print("FAIL: delete forgets the preview: \(error)"); exit(1) }
    }
    let retryURL = "https://example.com/?code=retry"
    cache.failures[retryURL] = Date()
    cache.results[retryURL] = LinkPreviewResult(title: "explicit retry", subtitle: "example.com", image: nil, coordinate: nil)
    cache.savedAt[retryURL] = Date()
    var retried = false
    cache.load(retryURL, userInitiated: true) { result in retried = result?.title == "explicit retry" }
    check(retried && cache.failures[retryURL] == nil, "explicit retry bypasses the automatic failure cooldown")
    do {
        let history = root.appendingPathComponent("history")
        let clip = Clip(source: "Preview fixture", sourceID: "test.preview", kind: "链接", title: "original", text: "https://example.com/article", parts: [[ClipPart(type: "public.utf8-plain-text", data: Data("https://example.com/article".utf8))]])
        try HistoryStorage.write(Archive(clips: [clip]), to: history.appendingPathComponent("history.json"))
        let store = Store(root: history)
        let before = try Data(contentsOf: history.appendingPathComponent("history.json"))
        store.setRecordingLoadFailure("synthetic read-only state")
        let result = LinkPreviewResult(title: "Fetched title", subtitle: "example.com", image: nil, coordinate: nil)
        store.applyLinkPreview(result, to: clip)
        store.flush()
        check(store.archive.clips[0].linkTitle == clip.linkTitle, "read-only preview leaves memory unchanged")
        check(try Data(contentsOf: history.appendingPathComponent("history.json")) == before, "read-only preview leaves disk unchanged")
        store.setRecordingLoadFailure(nil)
        store.applyLinkPreview(result, to: clip)
        store.flush()
        check(try HistoryStorage.read(from: history.appendingPathComponent("history.json")).clips[0].linkTitle == "Fetched title\nexample.com", "writable preview metadata persists")
        let mutation = store.directoryMutation
        store.applyLinkPreview(result, to: clip)
        check(store.directoryMutation == mutation, "same preview does not trigger another save")
        do {
            // A new title is applied to memory only; the next save, `flush` or the delay writes it.
            let fresh = LinkPreviewResult(title: "Second title", subtitle: "example.com", image: nil, coordinate: nil)
            store.linkTitleSaveDelay = 0.05
            let before = store.directoryMutation
            store.applyLinkPreview(fresh, to: clip)
            check(store.directoryMutation == before && store.hasUnsavedLinkTitles && store.archive.clips[0].linkTitle == "Second title\nexample.com", "a link title is applied to memory without an immediate save")
            let deadline = Date().addingTimeInterval(2)
            while store.hasUnsavedLinkTitles && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            store.flush()
            check(store.directoryMutation == before + 1 && !store.hasUnsavedLinkTitles, "the delay writes the title with a single save")
            check(try HistoryStorage.read(from: history.appendingPathComponent("history.json")).clips[0].linkTitle == "Second title\nexample.com", "the delayed save persisted the title")
            store.linkTitleSaveDelay = 600
            store.applyLinkPreview(LinkPreviewResult(title: "Third title", subtitle: "example.com", image: nil, coordinate: nil), to: clip)
            store.save(); store.flush()
            check(!store.hasUnsavedLinkTitles && store.directoryMutation == before + 2, "another save carries a pending title, and nothing is saved again")
            store.applyLinkPreview(LinkPreviewResult(title: "Fourth title", subtitle: "example.com", image: nil, coordinate: nil), to: clip)
            store.flush()
            check(try HistoryStorage.read(from: history.appendingPathComponent("history.json")).clips[0].linkTitle == "Fourth title\nexample.com", "flush writes a pending title (quit)")
        }
        store.archive.clips[0].text = "https://example.com/edited"
        store.archive.clips[0].linkTitle = "edited marker"
        store.applyLinkPreview(result, to: clip)
        check(store.archive.clips[0].linkTitle == "edited marker", "late callback cannot overwrite an edited URL")
        store.archive.clips = []
        store.applyLinkPreview(result, to: clip)
        check(store.archive.clips.isEmpty, "late callback cannot recreate a deleted entry")
        store.flush()
    } catch { print("FAIL: preview boundary: \(error)"); exit(1) }
    check(!LinkPreviewResult(title: "t", subtitle: "s").isLasting, "a bare title is not cached")
    check(LinkPreviewResult(title: "t", subtitle: "s", image: NSImage(size: NSSize(width: 2, height: 2))).isLasting, "a result with a cover is cached")
    runAudioPreviewChecks(check)
    print("Link preview boundaries: \(checks) checks passed")
}

/// FLAC metadata and the audio preview's helpers, on synthetic files (no real music needed).
func runAudioPreviewChecks(_ check: (@autoclosure () throws -> Bool, String) -> Void) {
    func le(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
    func be(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    func block(_ type: UInt8, _ body: [UInt8], last: Bool = false) -> [UInt8] { [type | (last ? 0x80 : 0), UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body }
    func comments(_ entries: [String]) -> [UInt8] {
        let vendor: [UInt8] = Array("test".utf8)
        var out: [UInt8] = le(vendor.count); out += vendor; out += le(entries.count)
        for entry in entries { let bytes: [UInt8] = Array(entry.utf8); out += le(bytes.count); out += bytes }
        return out
    }
    func picture(_ kind: Int, _ payload: [UInt8]) -> [UInt8] {
        let mime: [UInt8] = Array("image/png".utf8)
        var out: [UInt8] = be(kind); out += be(mime.count); out += mime; out += be(0)
        for value in [1, 1, 24, 0, payload.count] { out += be(value) }
        return out + payload
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OpenPaste-audio-\(UUID())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func write(_ name: String, _ bytes: [UInt8]) -> URL { let url = dir.appendingPathComponent(name); try? Data(bytes).write(to: url); return url }
    let streamInfo = block(0, [UInt8](repeating: 0, count: 34))
    var song: [UInt8] = Array("fLaC".utf8); song += streamInfo
    song += block(4, comments(["title=心痛2009", "ARTIST=欢子", "Album=其实很寂寞", "EMPTY=", "noequals"]))
    song += block(6, picture(0, [1, 2, 3])); song += block(6, picture(3, [9, 9]), last: true); song += [0xFF, 0xF8]
    let full = write("song.flac", song)
    let parsed = FLACMetadata.read(full)
    check(parsed?.tags["TITLE"] == "心痛2009" && parsed?.tags["ARTIST"] == "欢子" && parsed?.tags["ALBUM"] == "其实很寂寞", "FLAC Vorbis comments parse with case-insensitive keys")
    check(parsed?.tags["EMPTY"] == nil, "empty tags are ignored")
    check(parsed?.picture == Data([9, 9]), "the front-cover picture wins over other pictures")
    var cut: [UInt8] = Array("fLaC".utf8); cut += streamInfo; cut += Array(block(4, comments(["TITLE=x"])).prefix(12))
    let truncated = write("cut.flac", cut)
    check(FLACMetadata.read(truncated)?.tags.isEmpty == true, "a truncated comment block yields no tags and no crash")
    check(FLACMetadata.read(write("not.flac", Array("ID3x".utf8))) == nil, "a non-FLAC file is rejected")
    check(FLACMetadata.picture(Data(be(3) + be(500))) == nil, "a picture header pointing past its data is rejected")
    check(AudioInfo.isAudio(URL(fileURLWithPath: "/a/b.flac")) && AudioInfo.isAudio(URL(fileURLWithPath: "/a/b.MP3")) && !AudioInfo.isAudio(URL(fileURLWithPath: "/a/b.pdf")), "audio files are recognised by type")
    check(AudioPreview.clock(0) == "0:00" && AudioPreview.clock(265.8) == "4:25" && AudioPreview.clock(3725) == "1:02:05" && AudioPreview.clock(-3) == "0:00", "playback times format as m:ss / h:mm:ss")
    check(AudioPreview.palette(for: "心痛2009") == AudioPreview.palette(for: "心痛2009"), "a song keeps the same placeholder colours")
    MainActor.assumeIsolated {
        @MainActor func card(_ path: String) -> AudioCardInfo? {
            var result: AudioCardInfo?
            AudioCardCache.shared.load(path) { result = $0 }
            let deadline = Date().addingTimeInterval(5)
            while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return result
        }
        let tagged = card(full.path)
        check(tagged?.title == "心痛2009" && tagged?.detail == "欢子 · 其实很寂寞", "audio card shows title and artist · album from the tags")
        check(AudioCardCache.shared.cached(full.path)?.title == "心痛2009", "audio card info is cached after the first read")
        let missing = card(dir.appendingPathComponent("gone/晴天.mp3").path)
        check(missing?.title == "晴天" && missing?.detail == nil && missing?.cover == nil, "a missing file shows just its name")
        check(tagged?.parsed == true && missing?.parsed == false, "only a file that reads as audio is titled 音频")
        var clip = Clip(source: "访达", sourceID: "com.apple.finder", kind: "文件", title: "song.flac", text: full.path, parts: [])
        check(clip.showsAudioTitle, "an unlabelled single audio file may be titled 音频")
        clip.userLabel = "文件"
        check(!clip.showsAudioTitle, "a user label (even “文件”) is kept")
        clip.userLabel = nil; clip.text = full.path + "\n" + full.path
        check(!clip.showsAudioTitle, "multi-file clips stay 文件")
    }
}
