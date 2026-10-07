import AppKit
import CryptoKit
import Carbon
import ImageIO


struct GlobalShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyName: String
    static let standard = GlobalShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), keyName: "V")
    var label: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyName
    }
    var valid: Bool {
        let allowed = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        let hasStrongModifier = modifiers & UInt32(controlKey | optionKey) != 0 || modifiers & UInt32(cmdKey | shiftKey) == UInt32(cmdKey | shiftKey)
        return keyCode < 128 && ![53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode) && modifiers & ~allowed == 0 && hasStrongModifier && !keyName.isEmpty
    }
    static func from(_ event: NSEvent) -> GlobalShortcut {
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        let specials: [UInt16: String] = [36: "↵", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        let name = specials[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "键\(event.keyCode)"
        return GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: mods, keyName: name)
    }
    static func load(from defaults: UserDefaults = .standard) -> GlobalShortcut {
        if let data = defaults.data(forKey: "globalShortcut"), let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data), shortcut.valid { return shortcut }
        return .standard
    }
    func save(to defaults: UserDefaults = .standard) { if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "globalShortcut") } }
}

struct ClipPart: Codable, Equatable {
    var type: String; var data: Data; var storageID: String? = nil
    static func == (lhs: ClipPart, rhs: ClipPart) -> Bool { lhs.type == rhs.type && lhs.data == rhs.data }
}
struct Clip: Codable, Identifiable {
    var id = UUID()
    var created = Date()
    var source: String
    var sourceID: String
    var kind: String
    var title: String
    var text: String
    var parts: [[ClipPart]]
    var boards: [UUID] = []
    var ocrText: String?
    var userLabel: String?
    var linkTitle: String?
    var cachedDigest: String?
    var cardTitle: String {
        if let label = userLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { return label }
        if MapLink.parse(text) != nil { return "地图" }
        if source == "快速翻译" { return "翻译" }
        if kind == "文字", CodeSyntax.language(text) != nil { return "代码" }
        return kind
    }
    var byteCount: Int { parts.flatMap { $0 }.reduce(0) { $0 + $1.data.count } }
    var fingerprint: String {
        if let cachedDigest = cachedDigest { return cachedDigest }
        var bytes = Data()
        for item in parts { bytes.append(0); for part in item.sorted(by: { $0.type < $1.type }) { bytes.append(Data(part.type.utf8)); bytes.append(0); bytes.append(part.data) } }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    var image: NSImage? {
        for item in parts { for part in item where ["public.png", "public.tiff", "public.jpeg"].contains(part.type) { if let image = NSImage(data: part.data) { return image } } }
        return nil
    }
}
struct Board: Codable, Identifiable { var id = UUID(); var name: String; var color: String? = nil }
struct Archive: Codable { var clips: [Clip] = []; var boards: [Board] = [] }
private final class PendingImageCapture {
    var clip: Clip?
    let preserveExisting: Bool
    init(preserveExisting: Bool) { self.preserveExisting = preserveExisting }
}

private final class SaveGeneration {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func isCurrent(_ generation: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == value }
}
final class Store: ObservableObject {
    @Published var archive = Archive() { didSet { refreshResults() } }
    @Published var paused = false
    @Published var translating = false
    @Published var translationStatus = ""
    var selectionCaptureActive = false
    @Published var message = "所有内容仅保存在这台 Mac"
    @Published var query = "" { didSet { refreshResults() } }
    @Published var board: UUID? { didSet { refreshResults() } }
    @Published var kind = "全部" { didSet { refreshResults() } }
    @Published var sourceFilter = "全部来源" { didSet { refreshResults() } }
    @Published var filtersExpanded = false
    @Published var dateRangeEnabled = false { didSet { refreshResults() } }
    @Published var startDate = Date().addingTimeInterval(-7 * 86400) { didSet { refreshResults() } }
    @Published var endDate = Date() { didSet { refreshResults() } }
    @Published var todayOnly = false { didSet { refreshResults() } }
    @Published var reverseHistory = false { didSet { if reverseHistory != oldValue { selection.removeAll(); selectionAnchor = nil; refreshResults(); if reverseHistory { selected = filtered.first?.id } } } }
    private(set) var visibleClips: [Clip] = []
    private(set) var sourceNames: [String] = []
    private(set) var filterPasses = 0
    @Published var selected: UUID?
    var storageLimitMB = max(200, UserDefaults.standard.integer(forKey: "storageLimitMB"))
    var maxArchiveBytes: Int { storageLimitMB * 1024 * 1024 }
    @Published var importProgress = ImportProgress(phase: "", completed: 0, total: 0)
    var applyingImport = false
    @Published var importingPaste = false
    @Published var settings = false
    @Published var shortcutLabel = GlobalShortcut.load().label
    @Published var recordingShortcut = false
    @Published var shortcutNotice = ""
    @Published var directPasteAuthorized = false
    @Published var permissionStatus = "未授权"
    @Published var searchFocused = false
    @Published var searchExpanded = false
    @Published var pasteQueue: [UUID] = []
    @Published var selection = Set<UUID>()
    @Published var compact = false
    @Published var networkPreviews = UserDefaults.standard.object(forKey: "networkPreviews") as? Bool ?? true { didSet { if usePreferences { UserDefaults.standard.set(networkPreviews, forKey: "networkPreviews") }; LinkPreviewCache.shared.enabled = networkPreviews } }
    @Published var indexingImages = false
    @Published var ocrProgress = ""
    var draggingIDs: [UUID] = []
    var dragStartedAt = Date.distantPast
    var selectionAnchor: UUID?
    var undoItems: [ItemUndo] = []
    let ocrQueue = DispatchQueue(label: "openpaste.ocr", qos: .utility)
    @Published var retentionDays = UserDefaults.standard.integer(forKey: "retentionDays") { didSet { if usePreferences { UserDefaults.standard.set(retentionDays, forKey: "retentionDays") }; prune(); save() } }
    @Published var currentClipID: UUID?
    @Published var captureNotice = ""
    private let saveGeneration = SaveGeneration()
    let persistenceQueue = DispatchQueue(label: "openpaste.persistence", qos: .utility)
    let captureQueue = DispatchQueue(label: "openpaste.image-capture", qos: .userInitiated)
    private var captureGeneration = 0
    private var pendingImages: [Int: PendingImageCapture] = [:]
    @Published var root: URL
    @Published var changingDataDirectory = false
    @Published var directoryStatus = ""
    @Published var directoryProgress = ImportProgress(phase: "", completed: 0, total: 0)
    var syncBaseline = DataDirectory.baseline(Archive())
    var syncStamp = ""
    var initialDirectoryLoadFailed = false
    var syncChecking = false
    var directoryMutation = 0
    var syncTimer: Timer?
    var limit: Int { didSet { if usePreferences { UserDefaults.standard.set(limit, forKey: "historyLimit") }; if !applyingImport { prune(); save() } } }
    var ignored: String { didSet { if usePreferences { UserDefaults.standard.set(ignored, forKey: "ignoredApps") } } }
    var timer: Timer?
    var deletedCurrentChange: Int?
    var deletedCurrentID: UUID?
    var change = NSPasteboard.general.changeCount
    let ephemeral: Bool
    let usePreferences: Bool
    init(root: URL? = nil, ephemeral: Bool = false) {
        self.ephemeral = ephemeral
        self.usePreferences = root == nil && !ephemeral
        self.root = root ?? (ephemeral ? DataDirectory.defaultRoot : UserDefaults.standard.string(forKey: "dataDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? DataDirectory.defaultRoot)
        limit = UserDefaults.standard.object(forKey: "historyLimit") as? Int ?? 1000
        ignored = UserDefaults.standard.string(forKey: "ignoredApps") ?? "com.1password.1password\ncom.agilebits.onepassword7\ncom.bitwarden.desktop\ncom.apple.Passwords"
        if !ephemeral {
            do {
                try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = self.root.appendingPathComponent("history.json")
                if DataDirectory.usesSync(self.root) || FileManager.default.fileExists(atPath: file.path) {
                    syncBaseline = try DataDirectory.load(self.root)
                    if DataDirectory.usesSync(self.root), let cached = try DataDirectory.cached(self.root) { syncBaseline = DataDirectory.merge(syncBaseline, cached) }
                    archive = syncBaseline.archive
                    // A successful migration must survive a crash before preference updates.
                    storageLimitMB = max(storageLimitMB, (archive.clips.reduce(0) { $0 + $1.byteCount } + 1048575) / 1048576)
                    if limit != 0 { limit = max(limit, archive.clips.filter { $0.boards.isEmpty }.count) }
                    prune() }
            } catch {
                message = "历史加载失败：\(error.localizedDescription)。请勿继续录制，先检查数据。"; paused = true
                if DataDirectory.isCloud(self.root) {
                    directoryStatus = "等待同步：\(error.localizedDescription)"; initialDirectoryLoadFailed = true
                    if let cached = try? DataDirectory.cached(self.root) { syncBaseline = cached; archive = cached.archive }
                }
            }
        }
        refreshResults()
    }
    var filtered: [Clip] { visibleClips }
    var sources: [String] { sourceNames }
    private func refreshResults() {
        filterPasses += 1
        visibleClips = archive.clips.filter { c in
            (board == nil || c.boards.contains(board!)) && (kind == "全部" || c.kind == kind) &&
            (sourceFilter == "全部来源" || c.source == sourceFilter) && (!todayOnly || Calendar.current.isDateInToday(c.created)) && (!dateRangeEnabled || (c.created >= Calendar.current.startOfDay(for: startDate) && c.created < Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: endDate))!)) &&
            (query.isEmpty || [c.title, c.text, c.source, c.ocrText ?? "", c.linkTitle ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(query))
        }
        if reverseHistory { visibleClips.reverse() }
        selection.formIntersection(Set(visibleClips.map(\.id)))
        sourceNames = Array(Set(archive.clips.map(\.source))).sorted()
        if !visibleClips.contains(where: { $0.id == selected }) { selected = visibleClips.first?.id }
    }
    func moveSelection(_ delta: Int) {
        guard !visibleClips.isEmpty else { return }
        let index = visibleClips.firstIndex(where: { $0.id == selected }) ?? 0
        selection.removeAll()
        selected = visibleClips[max(0, min(visibleClips.count - 1, index + delta))].id; selectionAnchor = selected
    }
    func prune() {
        var count = 0
        if retentionDays > 0 { let cutoff = Date().addingTimeInterval(-Double(retentionDays * 86400)); archive.clips.removeAll { $0.boards.isEmpty && $0.created < cutoff } }
        var bytes = archive.clips.filter { !$0.boards.isEmpty }.reduce(0) { $0 + $1.byteCount }
        archive.clips = archive.clips.filter { c in if !c.boards.isEmpty { return true }; count += 1; bytes += c.byteCount; return (limit == 0 || count <= limit) && bytes <= maxArchiveBytes }
    }
    func save() {
        guard !ephemeral, !changingDataDirectory else { return }
        directoryMutation += 1
        let snapshot = archive
        let undoClips = undoItems.flatMap(\.clips)
        let folder = root
        let cloud = DataDirectory.usesSync(folder)
        if cloud { syncBaseline = DataDirectory.changes(snapshot, from: syncBaseline) }
        let baseline = syncBaseline
        let device = DataDirectory.deviceID
        let mutation = directoryMutation
        let generation = saveGeneration.next()
        let gate = saveGeneration
        let url = root.appendingPathComponent("history.json")
        persistenceQueue.async { [weak self] in
            guard gate.isCurrent(generation) else { return }
            do {
                if cloud {
                    try DataDirectory.cache(baseline, root: folder)
                    let merged = DataDirectory.merge(try DataDirectory.load(folder), DataDirectory.changes(snapshot, from: baseline))
                    try DataDirectory.write(merged, root: folder, device: device)
                    DispatchQueue.main.async {
                        guard let self, self.root == folder, self.directoryMutation == mutation, !self.changingDataDirectory else { return }
                        self.syncBaseline = merged; self.archive = merged.archive
                        self.directoryStatus = "已保存到 iCloud 目录；上传与下载由系统完成。"
                    }
                } else {
                    try DataDirectory.coordinated(url, writing: true) { path in try HistoryStorage.write(snapshot, to: path) }
                }
                if cloud {
                    // Local indexes cannot prove that an offline device no longer needs a shared blob.
                    try? HistoryStorage.collectUnused(at: DataDirectory.cacheURL(folder).deletingLastPathComponent(), preserving: undoClips)
                } else {
                    try? DataDirectory.coordinated(folder, writing: true) { path in
                        try HistoryStorage.collectUnused(at: path, preserving: undoClips)
                    }
                }
            } catch {
                let detail = error.localizedDescription
                DispatchQueue.main.async {
                    if cloud { self?.directoryStatus = "等待同步：\(detail)" }
                    else { self?.message = "保存失败：\(detail)"; self?.paused = true }
                }
            }
        }
    }
    func finishDirectoryCapture() {
        for generation in pendingImages.keys.sorted() { finishPendingImage(generation) }
    }
    func flush() {
        captureQueue.sync {}
        for generation in pendingImages.keys.sorted() { finishPendingImage(generation) }
        persistenceQueue.sync {}
    }
    func start() {
        guard !ephemeral else { return }
        capture(force: true)
        if syncTimer == nil {
            syncTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.pollDirectory() }
            if let syncTimer { RunLoop.main.add(syncTimer, forMode: .common) }
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.capture() }
        if let timer = timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func capture(force: Bool = false, pasteboard pb: NSPasteboard = .general) {
        guard !selectionCaptureActive, !paused, force || pb.changeCount != change else { return }
        if deletedCurrentChange == pb.changeCount { return }
        if deletedCurrentChange != nil { deletedCurrentChange = nil; deletedCurrentID = nil }
        if force, pb.changeCount == change, pendingImages[captureGeneration] != nil { return }
        if force, pb.changeCount == change, let id = currentClipID, archive.clips.contains(where: { $0.id == id }) { return }
        let changed = pb.changeCount != change
        change = pb.changeCount
        let app = NSWorkspace.shared.frontmostApplication
        captureContents(pb, source: changed ? app?.localizedName ?? "未知应用" : "当前剪贴板", sourceID: app?.bundleIdentifier ?? "", backgroundImages: true, preserveExisting: force)
    }
    func captureContents(_ pb: NSPasteboard, source: String, sourceID: String, backgroundImages: Bool = false, preserveExisting: Bool = false) {
        guard !paused else { return }
        captureGeneration += 1
        let generation = captureGeneration
        currentClipID = nil
        captureNotice = ""
        let ignoredIDs = ignored.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !ignoredIDs.contains(sourceID) else { captureNotice = "当前来源应用已排除，不会保存到历史"; return }
        let prohibited = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        guard !(pb.pasteboardItems ?? []).contains(where: { item in item.types.contains { prohibited.contains($0.rawValue) } }) else { captureNotice = "当前内容带有敏感或临时标记，未保存"; return }
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if files.isEmpty {
            let items = pb.pasteboardItems ?? []
            // One lossless screenshot representation is enough. Do not add the
            // uncompressed TIFF and PNG sizes together and reject ordinary captures.
            let types = ["public.png", "public.jpeg", "public.tiff"]
            let image = types.lazy.compactMap { type -> ClipPart? in
                for item in items { if let data = item.data(forType: NSPasteboard.PasteboardType(type)) { return ClipPart(type: type, data: data) } }
                return nil
            }.first
            if let image = image {
                let created = Date()
                let makeClip: () -> Clip? = {
                    guard let part = ImageCapture.normalize(image), part.data.count <= 20 * 1024 * 1024 else { return nil }
                    var clip = Clip(created: created, source: source, sourceID: sourceID, kind: "图片", title: "复制的图片", text: "", parts: [[part]])
                    clip.cachedDigest = clip.fingerprint
                    return clip
                }
                if backgroundImages {
                    captureNotice = "正在保存图片到历史…"
                    let job = PendingImageCapture(preserveExisting: preserveExisting)
                    pendingImages[generation] = job
                    captureQueue.async { [weak self] in
                        job.clip = makeClip()
                        DispatchQueue.main.async { self?.finishPendingImage(generation) }
                    }
                } else { finishCapture(makeClip(), preserveExisting: preserveExisting, generation: generation) }
                return
            }
        }
        var total = 0
        let parts: [[ClipPart]] = (pb.pasteboardItems ?? []).compactMap { item in
            let p = item.types.compactMap { type -> ClipPart? in
                guard let data = item.data(forType: type) else { return nil }
                total += data.count
                guard total <= 20 * 1024 * 1024 else { return nil }
                return ClipPart(type: type.rawValue, data: data)
            }
            return p.isEmpty ? nil : p
        }
        guard total <= 20 * 1024 * 1024 else { captureNotice = "超过 20 MB，未保存到历史"; return }
        guard !parts.isEmpty else { return }
        let text = pb.string(forType: .string) ?? pb.string(forType: .URL) ?? ""
        let isImage = parts.flatMap { $0 }.contains { ["public.png", "public.tiff", "public.jpeg"].contains($0.type) }
        let isLink = text.trimmingCharacters(in: .whitespacesAndNewlines).range(of: "^https?://[^\\s]+$", options: .regularExpression) != nil
        let isColor = CapturedColor.parse(text) != nil
        let kind = !files.isEmpty ? "文件" : (isImage ? "图片" : (isLink ? "链接" : (isColor ? "颜色" : "文字")))
        let title = !files.isEmpty ? files.map(\.lastPathComponent).joined(separator: ", ") : (isImage ? "复制的图片" : String(text.split(separator: "\n").first.map(String.init)?.prefix(100) ?? "内容"))
        finishCapture(Clip(source: source, sourceID: sourceID, kind: kind, title: title, text: files.isEmpty ? text : files.map(\.path).joined(separator: "\n"), parts: parts), preserveExisting: preserveExisting, generation: generation)
    }
    private func finishPendingImage(_ generation: Int) {
        guard let job = pendingImages.removeValue(forKey: generation) else { return }
        finishCapture(job.clip, preserveExisting: job.preserveExisting, generation: generation)
    }
    private func finishCapture(_ clip: Clip?, preserveExisting: Bool, generation: Int) {
        guard !paused else { return }
        guard let clip = clip else { if generation == captureGeneration { captureNotice = "图片无法读取或压缩后超过 20 MB，未保存到历史" }; return }
        let id = ingest(clip, preserveExisting: preserveExisting)
        if generation == captureGeneration { currentClipID = id; captureNotice = id == nil ? "历史容量已满，未保存当前内容" : "" }
    }
    @discardableResult func ingest(_ clip: Clip, preserveExisting: Bool = false) -> UUID? {
        var new = clip
        new.cachedDigest = new.fingerprint
        var items = archive.clips
        for index in items.indices where items[index].cachedDigest == nil { items[index].cachedDigest = items[index].fingerprint }
        let reserved = items.filter { !$0.boards.isEmpty && $0.fingerprint != new.fingerprint }.reduce(0) { $0 + $1.byteCount }
        guard reserved + clip.byteCount <= maxArchiveBytes else { message = "收藏内容已占满容量上限，请先清理部分内容"; return nil }
        if let i = items.firstIndex(where: { $0.fingerprint == new.fingerprint }) {
            if preserveExisting || items[i].created > new.created { return items[i].id }
            let old = items.remove(at: i); new.id = old.id; new.boards = old.boards
            new.userLabel = old.userLabel
            if let label = old.userLabel, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { new.title = old.title }
        }
        items.append(new); items.sort { $0.created > $1.created }; archive.clips = items; prune(); save()
        if new.kind == "链接", networkPreviews, !ephemeral { enrichLink(new) }
        return new.id
    }
    func delete(_ id: UUID, recordUndo: Bool = true) {
        if recordUndo, let clip = archive.clips.first(where: { $0.id == id }) { remember([clip], label: "删除") }
        if currentClipID == id {
            deletedCurrentChange = change
            deletedCurrentID = id
            currentClipID = nil
        }
        let before = filtered
        let index = before.firstIndex(where: { $0.id == id })
        let wasSelected = selected == id
        archive.clips.removeAll { $0.id == id }
        if wasSelected, let index = index { let remaining = filtered; selected = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id }
        save()
    }
    func pin(_ clip: Clip, to board: UUID) {
        guard let i = archive.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        if archive.clips[i].boards.contains(board) { archive.clips[i].boards.removeAll { $0 == board } } else { archive.clips[i].boards.append(board) }; save()
    }
    func addBoard(_ name: String) { let name = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty else { return }; archive.boards.append(Board(name: name)); save() }
    func setBoardColor(_ id: UUID, color: String) { guard let i = archive.boards.firstIndex(where: { $0.id == id }) else { return }; archive.boards[i].color = color; save() }
    func removeBoard(_ id: UUID) { archive.boards.removeAll { $0.id == id }; for i in archive.clips.indices { archive.clips[i].boards.removeAll { $0 == id } }; if board == id { board = nil }; prune(); save() }
    func clearHistory() {
        if let id = currentClipID, archive.clips.contains(where: { $0.id == id && $0.boards.isEmpty }) {
            deletedCurrentChange = change; deletedCurrentID = id; currentClipID = nil
        }
        archive.clips.removeAll { $0.boards.isEmpty }; save()
    }
    func restore(_ clip: Clip, plain: Bool, pasteboard pb: NSPasteboard = .general) -> Bool {
        let objects: [NSPasteboardItem]
        if plain {
            guard !clip.text.isEmpty, clip.kind != "图片", clip.kind != "文件" else { return false }
            let p = NSPasteboardItem(); p.setString(clip.text, forType: .string); objects = [p]
        } else {
            objects = clip.exportParts().map { parts in let p = NSPasteboardItem(); for part in parts { p.setData(part.data, forType: NSPasteboard.PasteboardType(part.type)) }; return p }
        }
        pb.clearContents(); let ok = pb.writeObjects(objects); change = pb.changeCount
        currentClipID = ok && archive.clips.contains(where: { $0.id == clip.id }) ? clip.id : nil
        if ok { recordUse([clip]) }
        return ok
    }
    func recordUse(_ clips: [Clip]) {
        var seen = Set<UUID>()
        let ids = clips.map(\.id).filter { seen.insert($0).inserted }
        var items = archive.clips
        let latest = items.map(\.created).max() ?? .distantPast
        let timestamp = max(Date(), latest.addingTimeInterval(0.001))
        var changed = false
        for (offset, id) in ids.enumerated() {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            items[index].created = timestamp.addingTimeInterval(Double(ids.count - offset) * 0.001)
            changed = true
        }
        guard changed else { return }
        items.sort { $0.created > $1.created }
        archive.clips = items
        save()
    }
    func demo() {
        let board = Board(name: "常用内容"); archive.boards = [board, Board(name: "项目灵感")]
        let samples = [("文字", "产品设计笔记", "好的工具应该让操作变得自然。\n\n历史记录、即时搜索、收藏板。\n全部保存在本机，随时取用。", "备忘录"), ("链接", "Apple Developer", "https://developer.apple.com/documentation/appkit", "Safari"), ("文字", "一段常用代码", "struct Idea {\n    let title: String\n    let created: Date\n}\n\n// Keep it local.", "Xcode"), ("文字", "每周工作总结", "本周完成\n• 交互方案\n• 核心功能开发\n\n下周计划\n• 验证实际使用体验", "Pages")]
        archive.clips = samples.enumerated().map { i, s in Clip(created: Date().addingTimeInterval(Double(-i * 420)), source: s.3, sourceID: "", kind: s.0, title: s.1, text: s.2, parts: [[ClipPart(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(s.2.utf8))]], boards: i == 0 ? [board.id] : []) }
        selected = archive.clips.first?.id
    }
}

struct ImageCapture {
    static func normalize(_ part: ClipPart) -> ClipPart? {
        guard part.data.count <= 256 * 1024 * 1024 else { return nil }
        if part.type != "public.tiff" { return part }
        guard let source = CGImageSourceCreateWithData(part.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 80_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ClipPart(type: "public.png", data: data as Data)
    }
}

struct MapLink {
    let url: URL
    let name: String
    let coordinate: String?
    let route: String?
    static func parse(_ text: String) -> MapLink? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host?.lowercased(), ["maps.apple.com", "www.maps.apple.com"].contains(host), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        let raw = value("ll") ?? value("center") ?? value("coordinate")
        var coordinate: String?
        if let raw { let pair = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }; if pair.count == 2, pair.allSatisfy({ $0.isFinite }), abs(pair[0]) <= 90, abs(pair[1]) <= 180 { coordinate = String(format: "%.6f, %.6f", pair[0], pair[1]) } }
        let destination = value("daddr") ?? value("destination")
        let route = destination.map { (value("saddr") ?? value("source") ?? "当前位置") + " → " + $0 }
        let name = [value("name"), value("q"), value("query"), value("address"), destination].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? (coordinate == nil ? "Apple 地图链接" : "地图位置")
        return MapLink(url: url, name: name, coordinate: coordinate, route: route)
    }
}
