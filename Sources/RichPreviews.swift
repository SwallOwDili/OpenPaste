import AppKit
import SwiftUI
import LinkPresentation
import MapKit
import CoreLocation
import CryptoKit

struct LinkPreviewResult {
    var title: String
    var subtitle: String
    var image: NSImage?
    var coordinate: CLLocationCoordinate2D?
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
    }
    static func allowed(_ url: URL) -> Bool { LinkPreviewPolicy.automatic(url) }
    func fileKey(_ text: String) -> String { HistoryStorage.hex(SHA256.hash(data: Data(("v2:" + text).utf8))) }
    func load(_ text: String, userInitiated: Bool = false, completion: @escaping (LinkPreviewResult?) -> Void) {
        guard enabled, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), LinkPreviewPolicy.canLoad(url), userInitiated || Self.allowed(url) else { completion(nil); return }
        let key = url.absoluteString
        if userInitiated { failures.removeValue(forKey: key) }
        else if let failed = failures[key], Date().timeIntervalSince(failed) < 600 { completion(nil); return }
        if let value = results[key], let date = savedAt[key], Date().timeIntervalSince(date) < ttl { completion(value); return }
        results.removeValue(forKey: key); savedAt.removeValue(forKey: key)
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
                cached = LinkPreviewResult(title: saved.title, subtitle: saved.subtitle, image: self.imageURL(for: saved, file: file).flatMap { NSImage(contentsOf: $0) }, coordinate: saved.latitude.flatMap { lat in saved.longitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) } })
                cachedDate = date
            }
            DispatchQueue.main.async {
                guard self.requests[key] === request, !request.cancelled else { return }
                if let cached, let cachedDate { self.finish(key, cached, request: request, cachedAt: cachedDate); return }
                self.jobs.append((key, {
                    guard self.requests[key] === request, !request.cancelled else { return }
                    request.usesNetworkSlot = true; self.active += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.finish(key, nil, request: request) }
                    let completion: (LinkPreviewResult?) -> Void = { self.finish(key, $0, request: request) }
                    if let map = MapLink.parse(text) { self.loadMap(map, request: request, completion: completion) }
                    else { self.loadWeb(url, request: request, completion: completion) }
                }))
                self.runNext()
            }
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
        let image = result.image
        imageQueue.async {
            guard !write.cancelled else { return }
            let png = image.flatMap(self.imageEncoder)
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
                    let saved = Saved(title: result.title, subtitle: result.subtitle, latitude: result.coordinate?.latitude, longitude: result.coordinate?.longitude, imageFile: imageURL?.lastPathComponent, generation: write.generation)
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
                if self.results.count > 50 { self.results.removeAll(); self.savedAt.removeAll() }
                self.results[key] = result; self.savedAt[key] = cachedAt ?? Date()
                if cachedAt == nil { self.save(result, for: key) }
            }
            if result == nil { if self.failures.count > 1000 { self.failures.removeAll() }; self.failures[key] = Date() }
            let callbacks = self.pending.removeValue(forKey: key) ?? []
            if request.usesNetworkSlot { request.usesNetworkSlot = false; self.active -= 1 }
            callbacks.forEach { $0(result) }; self.runNext()
        }
    }
    func loadWeb(_ url: URL, request: PreviewRequest, completion: @escaping (LinkPreviewResult?) -> Void) {
        let provider = LPMetadataProvider(); provider.timeout = 12
        request.add { provider.cancel() }
        provider.startFetchingMetadata(for: url) { metadata, _ in
            _ = provider
            guard !request.cancelled else { return }
            guard let metadata else { completion(nil); return }
            let title = metadata.title ?? url.host ?? "网页"
            let subtitle = (metadata.url ?? url).host ?? ""
            guard let image = metadata.imageProvider ?? metadata.iconProvider else { completion(LinkPreviewResult(title: title, subtitle: subtitle)); return }
            let progress = image.loadObject(ofClass: NSImage.self) { object, _ in
                guard !request.cancelled else { return }
                let bounded = (object as? NSImage).map { source -> NSImage in
                    let size = source.size; let ratio = min(1, 600 / max(1, max(size.width, size.height)))
                    let output = NSImage(size: NSSize(width: size.width * ratio, height: size.height * ratio))
                    output.lockFocus(); source.draw(in: NSRect(origin: .zero, size: output.size)); output.unlockFocus(); return output
                }
                completion(LinkPreviewResult(title: title, subtitle: subtitle, image: bounded))
            }
            request.add { progress.cancel() }
        }
    }
    func loadMap(_ map: MapLink, request: PreviewRequest, completion: @escaping (LinkPreviewResult?) -> Void) {
        let pair = map.coordinate?.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let center = pair.flatMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
        func snapshot(_ coordinate: CLLocationCoordinate2D, title: String, subtitle: String) {
            guard !request.cancelled else { return }
            let options = MKMapSnapshotter.Options()
            options.size = NSSize(width: 600, height: 380)
            options.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 500, longitudinalMeters: 500)
            options.showsBuildings = true
            let snapshotter = MKMapSnapshotter(options: options)
            snapshotter.start { shot, _ in
                guard !request.cancelled else { return }
                _ = snapshotter
                guard let shot else { completion(LinkPreviewResult(title: title, subtitle: subtitle, coordinate: coordinate)); return }
                let image = NSImage(size: options.size)
                image.lockFocus(); shot.image.draw(in: NSRect(origin: .zero, size: options.size))
                let point = shot.point(for: coordinate)
                NSColor.systemRed.setFill(); NSBezierPath(ovalIn: NSRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)).fill()
                NSColor.white.setStroke(); let ring = NSBezierPath(ovalIn: NSRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)); ring.lineWidth = 2; ring.stroke()
                image.unlockFocus()
                completion(LinkPreviewResult(title: title, subtitle: subtitle, image: image, coordinate: coordinate))
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
                if let item = response?.mapItems.min(by: { a, b in guard let center else { return false }; let origin = CLLocation(latitude: center.latitude, longitude: center.longitude); return origin.distance(from: CLLocation(latitude: a.placemark.coordinate.latitude, longitude: a.placemark.coordinate.longitude)) < origin.distance(from: CLLocation(latitude: b.placemark.coordinate.latitude, longitude: b.placemark.coordinate.longitude)) }) { snapshot(item.placemark.coordinate, title: item.name ?? map.name, subtitle: item.url?.host ?? item.placemark.title ?? "Apple 地图") }
                else if let center { snapshot(center, title: map.name, subtitle: map.route ?? map.coordinate ?? "Apple 地图") }
                else { completion(LinkPreviewResult(title: map.name, subtitle: "地点暂时无法解析")) }
            }
            request.add { search.cancel() }
        } else if let center {
            let geocoder = CLGeocoder()
            geocoder.reverseGeocodeLocation(CLLocation(latitude: center.latitude, longitude: center.longitude)) { places, _ in
                guard !request.cancelled else { return }
                _ = geocoder
                let place = places?.first
                snapshot(center, title: place?.name ?? map.name, subtitle: [place?.locality, place?.administrativeArea, place?.country].compactMap { $0 }.joined(separator: " · "))
            }
            request.add { geocoder.cancelGeocode() }
        } else { completion(LinkPreviewResult(title: map.name, subtitle: "此链接未提供可读取的地点或坐标")) }
        }
        if #available(macOS 15.0, *), let raw = URLComponents(url: map.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "place-id" })?.value, let identifier = MKMapItem.Identifier(rawValue: raw) {
            let mapRequest = MKMapItemRequest(mapItemIdentifier: identifier)
            mapRequest.getMapItem { item, _ in
                guard !request.cancelled else { return }
                _ = mapRequest
                if let item { snapshot(item.placemark.coordinate, title: item.name ?? map.name, subtitle: item.url?.host ?? item.placemark.title ?? "Apple 地图") }
                else { fallback() }
            }
            request.add { mapRequest.cancel() }
        } else { fallback() }
    }
}

struct RichLinkCard: View {
    let clip: Clip
    let enabled: Bool
    let store: Store
    @State var result: LinkPreviewResult?
    @State var finished = false
    @State private var userRequested = false
    private var needsExplicitLoad: Bool {
        guard let url = URL(string: clip.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return LinkPreviewPolicy.canLoad(url) && !LinkPreviewPolicy.automatic(url)
    }
    var body: some View {
        GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 8) {
            if let image = result?.image { Image(nsImage: image).resizable().scaledToFill().frame(maxWidth: .infinity).frame(height: max(28, geometry.size.height - 58)).clipped() }
            else if !finished && enabled { ProgressView("加载预览…").font(.caption).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if MapLink.parse(clip.text) != nil { Image(systemName: "map").font(.system(size: 30)).foregroundStyle(.green) }
            Text(clip.userLabel ?? result?.title ?? MapLink.parse(clip.text)?.name ?? clip.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).onTapGesture { Controller.shared.rename(clip) }
            Text(result?.subtitle ?? MapLink.parse(clip.text)?.coordinate ?? URL(string: clip.text)?.host ?? clip.text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if enabled && needsExplicitLoad && !userRequested {
                Button("点击加载预览") { userRequested = true; reload(userInitiated: true) }
                    .buttonStyle(.borderless).font(.system(size: 11))
                    .help("此链接可能属于内网或携带验证信息。点击会访问原网址。")
            } else if finished && result == nil {
                Text(enabled ? "预览不可用 · 原链接仍可使用" : "联网预览已关闭").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        }.onAppear { reload() }
            .onChange(of: enabled) { _, _ in userRequested = false; reload() }
            .onChange(of: clip.text) { _, _ in userRequested = false; result = nil; reload() }
    }
    func reload(userInitiated: Bool = false) {
        guard enabled else { result = nil; finished = true; return }
        finished = false
        LinkPreviewCache.shared.load(clip.text, userInitiated: userInitiated) { preview in
            guard store.networkPreviews else { result = nil; finished = true; return }
            result = preview; finished = true
            if preview == nil { userRequested = false }
            if let preview { store.applyLinkPreview(preview, to: clip) }
        }
    }
}
