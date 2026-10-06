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
    private var cleanupScheduled = false
    private var lastCleanup = Date.distantPast
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenPaste/LinkPreviews")
        scheduleCleanup()
    }
    func cleanDisk(now: Date = Date()) {
        precondition(!Thread.isMainThread, "Cache scans must run off the UI thread")
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var entries: [(URL, Date, Int)] = []
        for file in files where file.pathExtension == "json" {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let image = file.deletingPathExtension().appendingPathExtension("png")
            if now.timeIntervalSince(date) >= ttl { try? fm.removeItem(at: file); try? fm.removeItem(at: image); continue }
            let size = ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) + ((try? image.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            entries.append((file, date, size))
        }
        var bytes = entries.reduce(0) { $0 + $1.2 }
        for (file, _, size) in entries.sorted(by: { $0.1 < $1.1 }) where bytes > maxDiskBytes {
            try? fm.removeItem(at: file); try? fm.removeItem(at: file.deletingPathExtension().appendingPathExtension("png")); bytes -= size
        }
        for file in files where file.pathExtension == "png" && !fm.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("json").path) { try? fm.removeItem(at: file) }
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
        let callbacks = pending.values.flatMap { $0 }; pending.removeAll(); active = 0
        callbacks.forEach { $0(nil) }
    }
    struct Saved: Codable { var title: String; var subtitle: String; var latitude: Double?; var longitude: Double? }
    static func allowed(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil, let host = url.host?.lowercased(), host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".internal"), host != "localhost", !host.contains(":"), host.range(of: "^[0-9.]+$", options: .regularExpression) == nil else { return false }
        let forbidden = ["token", "key", "secret", "password", "auth", "signature", "credential"]
        return !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains { item in forbidden.contains { item.name.lowercased().contains($0) } }
    }
    func fileKey(_ text: String) -> String { SHA256.hash(data: Data(("v2:" + text).utf8)).map { String(format: "%02x", $0) }.joined() }
    func load(_ text: String, completion: @escaping (LinkPreviewResult?) -> Void) {
        guard enabled, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), Self.allowed(url) else { completion(nil); return }
        let key = url.absoluteString
        if let failed = failures[key], Date().timeIntervalSince(failed) < 600 { completion(nil); return }
        if let value = results[key], let date = savedAt[key], Date().timeIntervalSince(date) < ttl { completion(value); return }
        results.removeValue(forKey: key); savedAt.removeValue(forKey: key)
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
                cached = LinkPreviewResult(title: saved.title, subtitle: saved.subtitle, image: NSImage(contentsOf: file.appendingPathExtension("png")), coordinate: saved.latitude.flatMap { lat in saved.longitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) } })
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
    func finish(_ key: String, _ result: LinkPreviewResult?, request: PreviewRequest, cachedAt: Date? = nil) {
        DispatchQueue.main.async {
            guard self.requests[key] === request else { return }
            request.cancel(); self.requests.removeValue(forKey: key)
            if let result {
                if self.results.count > 50 { self.results.removeAll(); self.savedAt.removeAll() }
                self.results[key] = result; self.savedAt[key] = cachedAt ?? Date()
                if cachedAt == nil {
                    let file = self.root.appendingPathComponent(self.fileKey(key))
                    let saved = Saved(title: result.title, subtitle: result.subtitle, latitude: result.coordinate?.latitude, longitude: result.coordinate?.longitude)
                    let json = try? JSONEncoder().encode(saved)
                    let png = result.image?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
                    self.diskQueue.async {
                        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        if let png { try? png.write(to: file.appendingPathExtension("png"), options: .atomic) }
                        else { try? FileManager.default.removeItem(at: file.appendingPathExtension("png")) }
                        if let json { try? json.write(to: file.appendingPathExtension("json"), options: .atomic) }
                    }
                    self.scheduleCleanup(force: true)
                }
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
    var body: some View {
        GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 8) {
            if let image = result?.image { Image(nsImage: image).resizable().scaledToFill().frame(maxWidth: .infinity).frame(height: max(28, geometry.size.height - 58)).clipped() }
            else if !finished && enabled { ProgressView("加载预览…").font(.caption).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if MapLink.parse(clip.text) != nil { Image(systemName: "map").font(.system(size: 30)).foregroundStyle(.green) }
            Text(clip.userLabel ?? result?.title ?? MapLink.parse(clip.text)?.name ?? clip.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).onTapGesture { Controller.shared.rename(clip) }
            Text(result?.subtitle ?? MapLink.parse(clip.text)?.coordinate ?? URL(string: clip.text)?.host ?? clip.text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if finished && result?.image == nil { Text(enabled ? "预览不可用 · 原链接仍可使用" : "联网预览已关闭").font(.system(size: 10)).foregroundStyle(.tertiary) }
            Spacer(minLength: 0)
        }
        }.onAppear { reload() }.onChange(of: enabled) { _, _ in reload() }
    }
    func reload() { guard enabled else { result = nil; finished = true; return }; finished = false; LinkPreviewCache.shared.load(clip.text) { guard store.networkPreviews else { result = nil; finished = true; return }; result = $0; finished = true; if let preview = $0, let i = store.archive.clips.firstIndex(where: { $0.id == clip.id && $0.text == clip.text }), store.archive.clips[i].linkTitle != preview.title + "\n" + preview.subtitle { store.archive.clips[i].linkTitle = preview.title + "\n" + preview.subtitle; store.save() } } }
}
