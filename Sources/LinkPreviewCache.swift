import AppKit
import SwiftUI
import LinkPresentation
import MapKit
import CoreLocation
import CryptoKit
import UniformTypeIdentifiers

struct LinkPreviewResult {
    var title: String
    var subtitle: String
    /// Worth keeping on disk: anything beyond a bare title and domain.
    var isLasting: Bool { image != nil || coordinate != nil || icon != nil || videoTitle != nil }
    var image: NSImage?
    var coordinate: CLLocationCoordinate2D?
    /// YouTube: the video's own title, shown as the caption's first line (LinkPresentation's
    /// `title` there is the channel name, which moves to the second line).
    var videoTitle: String? = nil
    /// Leading caption-bar icon, shown by Messages for YouTube.
    var icon: NSImage? = nil
    /// Bubble colour: LinkPresentation's dominant image background colour.
    var background: NSColor? = nil
    /// A tiny copy of the image, shown enlarged as the frosted fill (made off the UI thread).
    var backdrop: NSImage? = nil
}

final class PreviewRequest {
    // Accessed only by the cache on the main thread, independently of cancellation.
    var usesNetworkSlot = false
    private let lock = NSLock()
    private var stopped = false
    private var cancellations: [() -> Void] = []
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func add(_ action: @escaping () -> Void) {
        lock.lock()
        if stopped { lock.unlock(); action() }
        else { cancellations.append(action); lock.unlock() }
    }
    func cancel() {
        lock.lock(); stopped = true; let actions = cancellations; cancellations.removeAll(); lock.unlock()
        actions.forEach { $0() }
    }
}
private final class PreviewCacheWrite {
    let generation = UUID().uuidString
    private let lock = NSLock()
    private enum State: Equatable { case pending, cancelled, committed }
    private var state = State.pending
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return state == .cancelled }
    @discardableResult func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .pending else { return false }
        state = .cancelled; return true
    }
    func commit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .pending else { return false }
        state = .committed; return true
    }
}

enum PreviewCacheWriteStage: Equatable { case beforeImage, imageWritten, metadataWritten }

final class LinkPreviewCache {
    static let shared = LinkPreviewCache()
    var results: [String: LinkPreviewResult] = [:]
    var failures: [String: Date] = [:]
    var pending: [String: [(LinkPreviewResult?) -> Void]] = [:]
    var jobs: [(String, () -> Void)] = []
    var active = 0
    var enabled = true { didSet { if !enabled { cancelAll() } } }
    var requests: [String: PreviewRequest] = [:]
    let ttl: TimeInterval = 7 * 86400
    var maxDiskBytes = 100 * 1024 * 1024
    var savedAt: [String: Date] = [:]
    /// Results kept in memory for `shortTTL` only (a title without a cover is not trusted for long).
    var shortLived: Set<String> = []
    let shortTTL: TimeInterval = 60
    let diskQueue = DispatchQueue(label: "openpaste.preview-cache", qos: .utility)
    let imageQueue = DispatchQueue(label: "openpaste.preview-image-encoding", qos: .utility)
    private let imageEncoder: (NSImage) -> Data?
    private let writeHook: ((PreviewCacheWriteStage, String) -> Void)?
    private var cacheWrites: [String: PreviewCacheWrite] = [:]
    private var cleanupScheduled = false
    private var lastCleanup = Date.distantPast
    let root: URL
    init(root: URL? = nil, imageEncoder: ((NSImage) -> Data?)? = nil, writeHook: ((PreviewCacheWriteStage, String) -> Void)? = nil) {
        if let root { self.root = root }
        else {
            do { self.root = try AppEnvironment.current.validateCacheRoot(AppEnvironment.current.previewCacheRoot) }
            catch { fatalError("Invalid preview cache root: \(error)") }
        }
        self.imageEncoder = imageEncoder ?? Self.encodePNG
        self.writeHook = writeHook
        scheduleCleanup()
    }
    private static func encodePNG(_ image: NSImage) -> Data? {
        precondition(!Thread.isMainThread, "Preview images must be encoded off the UI thread")
        return autoreleasepool {
            image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        }
    }
    func cleanDisk(now: Date = Date()) {
        precondition(!Thread.isMainThread, "Cache scans must run off the UI thread")
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var entries: [(URL, URL?, Date, Int)] = []
        var referencedImages = Set<String>()
        for file in files where file.pathExtension == "json" {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
            let image = saved.flatMap { imageURL(for: $0, file: file.deletingPathExtension()) }
            if now.timeIntervalSince(date) >= ttl { try? fm.removeItem(at: file); if let image { try? fm.removeItem(at: image) }; continue }
            if let image { referencedImages.insert(image.lastPathComponent) }
            let imageSize = image.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
            let size = ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) + imageSize
            entries.append((file, image, date, size))
        }
        var bytes = entries.reduce(0) { $0 + $1.3 }
        for (file, image, _, size) in entries.sorted(by: { $0.2 < $1.2 }) where bytes > maxDiskBytes {
            try? fm.removeItem(at: file); if let image { try? fm.removeItem(at: image); referencedImages.remove(image.lastPathComponent) }; bytes -= size
        }
        for file in files where file.pathExtension == "png" && !referencedImages.contains(file.lastPathComponent) { try? fm.removeItem(at: file) }
    }
    // Coalesce writes; disk-hit loads schedule at most one scan per minute.
    func scheduleCleanup(force: Bool = false) {
        guard !cleanupScheduled, force || Date().timeIntervalSince(lastCleanup) >= 60 else { return }
        cleanupScheduled = true
        diskQueue.asyncAfter(deadline: .now() + 0.1) {
            self.cleanDisk()
            DispatchQueue.main.async { self.cleanupScheduled = false; self.lastCleanup = Date() }
        }
    }
    func cancelAll() {
        jobs.removeAll()
        requests.values.forEach { $0.cancel() }; requests.removeAll()
        let writes = cacheWrites; cacheWrites.removeAll()
        for (key, write) in writes { cancel(write, for: key) }
        let callbacks = pending.values.flatMap { $0 }; pending.removeAll(); active = 0
        callbacks.forEach { $0(nil) }
    }
    struct Saved: Codable {
        var title: String
        var subtitle: String
        var latitude: Double? = nil
        var longitude: Double? = nil
        var imageFile: String? = nil
        var generation: String? = nil
        var videoTitle: String? = nil
        var icon: Data? = nil
        var background: [Double]? = nil
    }
    static func allowed(_ url: URL) -> Bool { LinkPreviewPolicy.automatic(url) }
    func fileKey(_ text: String) -> String { HistoryStorage.hex(SHA256.hash(data: Data(("v6:" + text).utf8))) }
    func load(_ text: String, userInitiated: Bool = false, completion: @escaping (LinkPreviewResult?) -> Void) {
        guard enabled, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), LinkPreviewPolicy.canLoad(url), userInitiated || Self.allowed(url) else { completion(nil); return }
        let key = url.absoluteString
        if userInitiated { failures.removeValue(forKey: key) }
        else if let failed = failures[key], Date().timeIntervalSince(failed) < 600 { completion(nil); return }
        if let value = results[key], let date = savedAt[key], Date().timeIntervalSince(date) < (shortLived.contains(key) ? shortTTL : ttl) { completion(value); return }
        results.removeValue(forKey: key); savedAt.removeValue(forKey: key); shortLived.remove(key)
        if let write = cacheWrites.removeValue(forKey: key) { cancel(write, for: key) }
        if pending[key] != nil { pending[key]?.append(completion); return }
        pending[key] = [completion]
        let request = PreviewRequest(); requests[key] = request
        let file = root.appendingPathComponent(fileKey(key))
        scheduleCleanup()
        // Local cache hits never consume or wait for a network slot.
        diskQueue.async {
            guard !request.cancelled else { return }
            var cached: LinkPreviewResult?
            var cachedDate: Date?
            if let date = try? file.appendingPathExtension("json").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(date) < self.ttl,
               let data = try? Data(contentsOf: file.appendingPathExtension("json")), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
                cached = LinkPreviewResult(title: saved.title, subtitle: saved.subtitle, image: self.imageURL(for: saved, file: file).flatMap { NSImage(contentsOf: $0) }, coordinate: saved.latitude.flatMap { lat in saved.longitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) } },
                                           videoTitle: saved.videoTitle, icon: saved.icon.flatMap(NSImage.init(data:)),
                                           background: saved.background.flatMap { $0.count == 4 ? NSColor(srgbRed: $0[0], green: $0[1], blue: $0[2], alpha: $0[3]) : nil })
                if let image = cached?.image { cached?.backdrop = frostedBackdrop(image) }
                cachedDate = date
            }
            DispatchQueue.main.async {
                guard self.requests[key] === request, !request.cancelled else { return }
                if let cached, let cachedDate { self.finish(key, cached, request: request, cachedAt: cachedDate); return }
                self.jobs.append((key, {
                    guard self.requests[key] === request, !request.cancelled else { return }
                    request.usesNetworkSlot = true; self.active += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.finish(key, nil, request: request) }
                    let completion: (LinkPreviewResult?) -> Void = { self.finish(key, $0, request: request) }
                    if let map = MapLink.parse(text) { self.loadMap(map, request: request, completion: completion) }
                    else { self.loadWeb(url, userInitiated: userInitiated, request: request, completion: completion) }
                }))
                self.runNext()
            }
        }
    }

    /// Drops everything kept for a link (memory, failure cooldown, disk) so the next `load` asks the network.
    func forget(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let key = url.absoluteString
        results.removeValue(forKey: key); savedAt.removeValue(forKey: key); failures.removeValue(forKey: key); shortLived.remove(key)
        if let write = cacheWrites.removeValue(forKey: key) { cancel(write, for: key) }
        let file = root.appendingPathComponent(fileKey(key))
        diskQueue.async {
            let json = file.appendingPathExtension("json")
            if let data = try? Data(contentsOf: json), let saved = try? JSONDecoder().decode(Saved.self, from: data), let image = self.imageURL(for: saved, file: file) {
                try? FileManager.default.removeItem(at: image)
            }
            try? FileManager.default.removeItem(at: json)
        }
    }

    func runNext() { guard enabled else { let queued = jobs; jobs.removeAll(); for (key, _) in queued { let callbacks = pending.removeValue(forKey: key) ?? []; callbacks.forEach { $0(nil) } }; return }; while active < 2 && !jobs.isEmpty { let job = jobs.removeFirst(); job.1() } }
    private func imageURL(for saved: Saved, file: URL) -> URL? {
        if let name = saved.imageFile, URL(fileURLWithPath: name).lastPathComponent == name { return root.appendingPathComponent(name) }
        return saved.generation == nil ? file.appendingPathExtension("png") : nil
    }
    private func cancel(_ write: PreviewCacheWrite, for key: String) {
        guard write.cancel() else { return }
        let file = root.appendingPathComponent(fileKey(key))
        diskQueue.async {
            let image = self.root.appendingPathComponent(file.lastPathComponent + "-" + write.generation + ".png")
            try? FileManager.default.removeItem(at: image)
            let json = file.appendingPathExtension("json")
            if let data = try? Data(contentsOf: json), let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.generation == write.generation { try? FileManager.default.removeItem(at: json) }
        }
    }
    private func save(_ result: LinkPreviewResult, for key: String) {
        if let old = cacheWrites.removeValue(forKey: key) { cancel(old, for: key) }
        let write = PreviewCacheWrite()
        cacheWrites[key] = write
        let file = root.appendingPathComponent(fileKey(key))
        let image = result.image, icon = result.icon
        imageQueue.async {
            guard !write.cancelled else { return }
            let png = image.flatMap(self.imageEncoder)
            let iconPNG = icon.flatMap(self.imageEncoder)
            guard !write.cancelled else { return }
            self.diskQueue.async {
                let fm = FileManager.default
                let jsonURL = file.appendingPathExtension("json")
                let imageURL = png.map { _ in self.root.appendingPathComponent(file.lastPathComponent + "-" + write.generation + ".png") }
                var committed = false
                do {
                    guard !write.cancelled else { return }
                    try fm.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    self.writeHook?(.beforeImage, key)
                    guard !write.cancelled else { return }
                    if let png, let imageURL { try png.write(to: imageURL, options: .atomic) }
                    self.writeHook?(.imageWritten, key)
                    guard !write.cancelled else { if let imageURL { try? fm.removeItem(at: imageURL) }; return }
                    let previousJSON = try? Data(contentsOf: jsonURL)
                    let previousDate = try? jsonURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    let previousSaved = previousJSON.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
                    let background = result.background?.usingColorSpace(.sRGB).map { [Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent), Double($0.alphaComponent)] }
                    let saved = Saved(title: result.title, subtitle: result.subtitle, latitude: result.coordinate?.latitude, longitude: result.coordinate?.longitude, imageFile: imageURL?.lastPathComponent, generation: write.generation, videoTitle: result.videoTitle, icon: iconPNG, background: background)
                    let json = try JSONEncoder().encode(saved)
                    guard !write.cancelled else { if let imageURL { try? fm.removeItem(at: imageURL) }; return }
                    try json.write(to: jsonURL, options: .atomic)
                    self.writeHook?(.metadataWritten, key)
                    if write.commit() {
                        committed = true
                        if let oldImage = previousSaved.flatMap({ self.imageURL(for: $0, file: file) }), oldImage != imageURL { try? fm.removeItem(at: oldImage) }
                    } else {
                        if let previousJSON {
                            try previousJSON.write(to: jsonURL, options: .atomic)
                            if let previousDate { try? fm.setAttributes([.modificationDate: previousDate], ofItemAtPath: jsonURL.path) }
                        } else { try? fm.removeItem(at: jsonURL) }
                        if let imageURL { try? fm.removeItem(at: imageURL) }
                    }
                } catch {
                    if let imageURL { try? fm.removeItem(at: imageURL) }
                }
                let didCommit = committed
                DispatchQueue.main.async {
                    guard self.cacheWrites[key] === write else { return }
                    self.cacheWrites.removeValue(forKey: key)
                    if didCommit { self.scheduleCleanup(force: true) }
                }
            }
        }
    }
    func finish(_ key: String, _ result: LinkPreviewResult?, request: PreviewRequest, cachedAt: Date? = nil) {
        DispatchQueue.main.async {
            guard self.requests[key] === request else { return }
            request.cancel(); self.requests.removeValue(forKey: key)
            if let result {
                if self.results.count > 50 { self.results.removeAll(); self.savedAt.removeAll(); self.shortLived.removeAll() }
                // A title without a cover is not kept: a slow page may deliver the cover next time. It stays in
                // memory for `shortTTL` only, so scrolling does not refetch.
                let lasting = cachedAt != nil || result.isLasting
                self.results[key] = result; self.savedAt[key] = cachedAt ?? Date()
                if lasting { self.shortLived.remove(key) } else { self.shortLived.insert(key) }
                if cachedAt == nil && lasting { self.save(result, for: key) }
            }
            if result == nil { if self.failures.count > 1000 { self.failures.removeAll() }; self.failures[key] = Date() }
            let callbacks = self.pending.removeValue(forKey: key) ?? []
            if request.usesNetworkSlot { request.usesNetworkSlot = false; self.active -= 1 }
            callbacks.forEach { $0(result) }; self.runNext()
        }
    }
    /// LinkPresentation first (what Messages uses). If it fails, or has not answered within
    /// `hedgeDelay`, the page's Open Graph tags are read directly as well. The first result with a
    /// cover image wins; without one, the LinkPresentation result (else the page's) is used once both
    /// have finished. A site icon is never used as the cover.
    func loadWeb(_ url: URL, userInitiated: Bool, request: PreviewRequest, completion: @escaping (LinkPreviewResult?) -> Void) {
        var done = false, fallbackStarted = false, systemDone = false, fallbackDone = false
        var systemPartial: LinkPreviewResult?, fallbackPartial: LinkPreviewResult?
        func deliver(_ result: LinkPreviewResult?) { guard !done, !request.cancelled else { return }; done = true; completion(result) }
        func settle() { if systemDone && fallbackDone { deliver(systemPartial ?? fallbackPartial) } }
        func startFallback() {
            guard !fallbackStarted, !done, !request.cancelled else { return }
            fallbackStarted = true
            let allowed: (URL) -> Bool = { userInitiated ? LinkPreviewPolicy.canLoad($0) : LinkPreviewPolicy.automaticResolved($0) }
            pageLoader(url, allowed, request) { result in
                DispatchQueue.main.async {
                    if result?.image != nil { deliver(result); return }
                    fallbackPartial = result; fallbackDone = true; settle()
                }
            }
        }
        // LPMetadataProvider checks neither redirects nor sub-resources: automatic previews of other sites use only the
        // restricted page loader. A link the user chose to load, and the listed sites, keep the system fetch.
        guard userInitiated || systemFetchAllowed(url) else { systemDone = true; startFallback(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + hedgeDelay) { startFallback() }
        systemLoader(url, request) { result in
            DispatchQueue.main.async {
                if result?.image != nil { deliver(result); return }
                // No cover from LinkPresentation (or no result): the page's og:image may still have one,
                // but a title already in hand is shown after `fallbackGrace` rather than lost to a slow page.
                systemPartial = result; systemDone = true
                startFallback(); settle()
                if result != nil { DispatchQueue.main.asyncAfter(deadline: .now() + self.fallbackGrace) { deliver(systemPartial) } }
            }
        }
    }
    /// Replaceable for tests.
    var systemFetchAllowed: (URL) -> Bool = LinkPreviewPolicy.systemFetchAllowed
    var hedgeDelay: TimeInterval = 4
    /// 10 s: a page that needs 5 to 8 s (GitHub over a slow link) still delivers its cover.
    var fallbackGrace: TimeInterval = 10
    /// Replaceable for tests.
    lazy var systemLoader: (URL, PreviewRequest, @escaping (LinkPreviewResult?) -> Void) -> Void = { [unowned self] in self.loadSystemMetadata($0, request: $1, completion: $2) }
    var pageLoader: (URL, @escaping (URL) -> Bool, PreviewRequest, @escaping (LinkPreviewResult?) -> Void) -> Void = { LinkPageMetadata.load($0, allowed: $1, request: $2, completion: $3) }
    private func loadSystemMetadata(_ url: URL, request: PreviewRequest, completion: @escaping (LinkPreviewResult?) -> Void) {
        let provider = LPMetadataProvider(); provider.timeout = 12
        request.add { provider.cancel() }
        provider.startFetchingMetadata(for: url) { metadata, _ in
            _ = provider
            guard !request.cancelled else { return }
            guard let metadata else { completion(nil); return }
            let pageURL = metadata.url ?? url
            // No title (an image URL, an untitled page): the domain stands in, the cover is still used.
            let title = metadata.title.flatMap { $0.isEmpty ? nil : $0 } ?? LinkPageMetadata.displayHost(pageURL)
            var result = LinkPreviewResult(title: title, subtitle: LinkPageMetadata.displayHost(pageURL))
            // YouTube: LinkPresentation's title is the channel. The video title comes from the page's
            // og:title (served to the link-preview crawler; Safari gets an empty, script-rendered page).
            // The summary ("N likes, M comments. …") is not used anywhere.
            let youTube = LinkPageMetadata.isYouTube(pageURL) && (metadata.remoteVideoURL != nil || metadata.videoProvider != nil)
            let group = DispatchGroup()
            let lock = NSLock()
            // The icon provider carries a private type NSImage cannot be coerced from; the
            // already-decoded icon is on LinkPresentation's `icon` (an LPImage with `platformImage`).
            if youTube, metadata.responds(to: NSSelectorFromString("icon")),
               let icon = metadata.value(forKey: "icon") as? NSObject, icon.responds(to: NSSelectorFromString("platformImage")) {
                result.icon = icon.value(forKey: "platformImage") as? NSImage
            }
            if youTube {
                group.enter()
                LinkPageMetadata.title(of: url, request: request) { videoTitle in
                    lock.lock(); result.videoTitle = videoTitle; lock.unlock()
                    group.leave()
                }
            }
            // Only the page image is a cover; the site icon is not (GitHub's would show the Octocat).
            for (provider, isIcon) in [(metadata.imageProvider, false), (youTube && result.icon == nil ? metadata.iconProvider : nil, true)] {
                guard let provider else { continue }
                group.enter()
                let store: (NSImage?) -> Void = { image in
                    lock.lock(); if isIcon { result.icon = image } else { result.image = image }; lock.unlock()
                    group.leave()
                }
                // From data, so a huge picture is refused or scaled while decoding instead of built at full size.
                if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                    let progress = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in store(data.flatMap { previewThumbnail(from: $0) }) }
                    request.add { progress.cancel() }
                } else {
                    let progress = provider.loadObject(ofClass: NSImage.self) { object, _ in store((object as? NSImage).map(boundedPreviewImage)) }
                    request.add { progress.cancel() }
                }
            }
            group.notify(queue: .global(qos: .utility)) {
                guard !request.cancelled else { return }
                if let image = result.image {
                    result.background = LinkPageMetadata.bubbleColor(metadata: metadata, url: pageURL) ?? LinkPageMetadata.bubbleColor(for: image, url: pageURL)
                    result.backdrop = frostedBackdrop(image)
                }
                completion(result)
            }
        }
    }
    func loadMap(_ map: MapLink, request: PreviewRequest, completion: @escaping (LinkPreviewResult?) -> Void) {
        let pair = map.coordinate?.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let center = pair.flatMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
        /// `localize`: look the address up again in the user's language (MapKit search answers in the
        /// app's). Off when the caller already has a localized address or a route to keep.
        func snapshot(_ coordinate: CLLocationCoordinate2D, title: String, subtitle: String, localize: Bool = true) {
            guard !request.cancelled else { return }
            // Messages: a square snapshot about 2 km across, drawn at the size it is shown (so map
            // labels stay legible), the place marked by a red balloon with its name underneath.
            let options = MKMapSnapshotter.Options()
            options.size = NSSize(width: 320, height: 320)
            options.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 2000, longitudinalMeters: 2000)
            options.showsBuildings = true
            // The marker carries the name; MapKit's own POI labels would repeat it beside the pin.
            options.pointOfInterestFilter = .excludingAll
            let snapshotter = MKMapSnapshotter(options: options)
            snapshotter.start { shot, _ in
                guard !request.cancelled else { return }
                _ = snapshotter
                guard let shot else { completion(LinkPreviewResult(title: title, subtitle: subtitle, coordinate: coordinate, background: LinkBubble.mapBackground)); return }
                let image = NSImage(size: options.size)
                image.lockFocus(); shot.image.draw(in: NSRect(origin: .zero, size: options.size))
                // The region is centred on the place, so the marker goes at the centre.
                drawMapMarker(at: NSPoint(x: options.size.width / 2, y: options.size.height / 2), name: title)
                image.unlockFocus()
                guard localize else { completion(LinkPreviewResult(title: title, subtitle: subtitle, image: image, coordinate: coordinate, background: LinkBubble.mapBackground)); return }
                // Address in the user's language (MapKit answers in the app's, which is English here).
                let geocoder = CLGeocoder()
                geocoder.reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), preferredLocale: Locale(identifier: Locale.preferredLanguages.first ?? "zh-Hans")) { places, _ in
                    _ = geocoder
                    guard !request.cancelled else { return }
                    completion(LinkPreviewResult(title: title, subtitle: places?.first.flatMap(mapAddress) ?? subtitle, image: image, coordinate: coordinate, background: LinkBubble.mapBackground))
                }
                request.add { geocoder.cancelGeocode() }
            }
            request.add { snapshotter.cancel() }
        }
        func fallback() {
        guard !request.cancelled else { return }
        if map.name != "地图位置" && map.name != "Apple 地图链接" {
            let searchRequest = MKLocalSearch.Request(); searchRequest.naturalLanguageQuery = map.name
            if let center { searchRequest.region = MKCoordinateRegion(center: center, latitudinalMeters: 3000, longitudinalMeters: 3000) }
            let search = MKLocalSearch(request: searchRequest)
            search.start { response, _ in
                guard !request.cancelled else { return }
                _ = search
                if let item = response?.mapItems.min(by: { a, b in guard let center else { return false }; let origin = CLLocation(latitude: center.latitude, longitude: center.longitude); return origin.distance(from: CLLocation(latitude: a.placemark.coordinate.latitude, longitude: a.placemark.coordinate.longitude)) < origin.distance(from: CLLocation(latitude: b.placemark.coordinate.latitude, longitude: b.placemark.coordinate.longitude)) }) { snapshot(item.placemark.coordinate, title: item.name ?? map.name, subtitle: mapAddress(item.placemark) ?? "Apple 地图") }
                else if let center { snapshot(center, title: map.name, subtitle: map.route ?? map.coordinate ?? "Apple 地图", localize: map.route == nil) }
                else { completion(LinkPreviewResult(title: map.name, subtitle: "地点暂时无法解析")) }
            }
            request.add { search.cancel() }
        } else if let center {
            let geocoder = CLGeocoder()
            geocoder.reverseGeocodeLocation(CLLocation(latitude: center.latitude, longitude: center.longitude), preferredLocale: Locale(identifier: Locale.preferredLanguages.first ?? "zh-Hans")) { places, _ in
                guard !request.cancelled else { return }
                _ = geocoder
                let place = places?.first
                snapshot(center, title: place?.name ?? map.name, subtitle: place.flatMap(mapAddress) ?? "Apple 地图", localize: false)
            }
            request.add { geocoder.cancelGeocode() }
        } else { completion(LinkPreviewResult(title: map.name, subtitle: "此链接未提供可读取的地点或坐标")) }
        }
        if #available(macOS 15.0, *), let raw = URLComponents(url: map.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "place-id" })?.value, let identifier = MKMapItem.Identifier(rawValue: raw) {
            let mapRequest = MKMapItemRequest(mapItemIdentifier: identifier)
            mapRequest.getMapItem { item, _ in
                guard !request.cancelled else { return }
                _ = mapRequest
                if let item { snapshot(item.placemark.coordinate, title: item.name ?? map.name, subtitle: mapAddress(item.placemark) ?? "Apple 地图") }
                else { fallback() }
            }
            request.add { mapRequest.cancel() }
        } else { fallback() }
    }
}
