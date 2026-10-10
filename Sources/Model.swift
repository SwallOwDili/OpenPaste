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
        let hasRequiredModifier = modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
        return keyCode < 128 && ![53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode) && modifiers & ~allowed == 0 && hasRequiredModifier && !keyName.isEmpty
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
    static func load(from defaults: UserDefaults = AppEnvironment.current.defaults) -> GlobalShortcut {
        if let data = defaults.data(forKey: "globalShortcut"), let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data), shortcut.valid { return shortcut }
        return .standard
    }
    func save(to defaults: UserDefaults = AppEnvironment.current.defaults) { if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "globalShortcut") } }
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
    var byteCount: Int { parts.reduce(0) { total, item in item.reduce(total) { $0 + $1.data.count } } }
    var fingerprint: String {
        if let cachedDigest = cachedDigest { return cachedDigest }
        var bytes = Data()
        for item in parts { bytes.append(0); for part in item.sorted(by: { $0.type < $1.type }) { bytes.append(Data(part.type.utf8)); bytes.append(0); bytes.append(part.data) } }
        return HistoryStorage.hex(SHA256.hash(data: bytes))
    }
    var image: NSImage? {
        for item in parts { for part in item where ["public.png", "public.tiff", "public.jpeg"].contains(part.type) { if let image = NSImage(data: part.data) { return image } } }
        return nil
    }
}
struct Board: Codable, Identifiable { var id = UUID(); var name: String; var color: String? = nil }
struct Archive: Codable { var clips: [Clip] = []; var boards: [Board] = [] }
struct ClipboardCaptureSource: Equatable {
    let name: String
    let bundleID: String
}
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
    @Published var archive = Archive() { didSet { rebuildSources(); refreshResults() } }
    @Published var paused = false
    private var pauseReasons = RecordingPauseReasons()
    var userPaused: Bool { pauseReasons.userPaused }
    var recordingSafetyPaused: Bool { pauseReasons.hasStorageFailure }
    var recordingNeedsConsent: Bool { !pauseReasons.recordingAccepted }
    var historyModificationNotice: String { initialLoading ? "正在读取历史，请稍后再试" : (hasHistoryLoadFailure ? "请先恢复历史读取，再修改内容" : "正在处理数据，请稍后再试") }
    var hasHistoryLoadFailure: Bool { pauseReasons.loadFailure != nil }
    var canModifyHistory: Bool { !initialLoading && !hasHistoryLoadFailure && !changingDataDirectory && !importingPaste }
    var recordingPauseControl: RecordingPauseControl { pauseReasons.control }
    @Published var translating = false
    @Published var translationStatus = ""
    @Published var translationSelectionAuthorized = false
    var selectionCaptureActive = false
    @Published var message = "所有内容仅保存在这台 Mac"
    /// Card whose title is being edited in place; nil when no inline rename is active.
    @Published var renamingID: UUID?
    @Published var query = "" { didSet { if query != oldValue { filterValueChanged() } } }
    @Published var board: UUID? { didSet { if board != oldValue { filterValueChanged() } } }
    @Published var kind = "全部" { didSet { if kind != oldValue { filterValueChanged() } } }
    @Published var sourceFilter = "全部来源" { didSet { if sourceFilter != oldValue { filterValueChanged() } } }
    @Published var filtersExpanded = false
    @Published var dateRangeEnabled = false { didSet { if dateRangeEnabled != oldValue { filterValueChanged() } } }
    @Published var startDate = Date().addingTimeInterval(-7 * 86400) { didSet { if startDate != oldValue { filterValueChanged() } } }
    @Published var endDate = Date() { didSet { if endDate != oldValue { filterValueChanged() } } }
    @Published var todayOnly = false { didSet { if todayOnly != oldValue { filterValueChanged() } } }
    @Published var reverseHistory = false { didSet { if reverseHistory != oldValue { selection.removeAll(); selectionAnchor = nil; filterValueChanged(); if reverseHistory { selected = filtered.first?.id } } } }
    private(set) var visibleClips: [Clip] = []
    private var visibleIndexByID: [UUID: Int] = [:]
    private(set) var sourceNames: [String] = []
    private(set) var filterPasses = 0
    private(set) var sourcePasses = 0
    private var batchingFilterChanges = false
    private var filterRefreshPending = false
    @Published var selected: UUID?
    var storageLimitMB: Int
    var maxArchiveBytes: Int { storageLimitMB * 1024 * 1024 }
    @Published var importProgress = ImportProgress(phase: "", completed: 0, total: 0)
    var applyingImport = false
    @Published var importingPaste = false
    @Published var settings = false
    @Published var shortcutLabel: String
    /// Shelf-local shortcuts (board switching, quick paste and plain-text modifiers).
    @Published var shelfShortcuts: ShelfShortcuts { didSet { if usePreferences { shelfShortcuts.save(to: configurationDefaults) } } }
    @Published var recordingChord: ShelfChordTarget?
    @Published var chordNotice = ""
    @Published var recordingShortcut = false
    @Published var shortcutNotice = ""
    @Published var directPasteAuthorized = false
    @Published var permissionStatus = "未授权"
    @Published var searchFocused = false
    @Published var searchExpanded = false
    @Published var pasteQueue: [UUID] = []
    @Published var selection = Set<UUID>()
    @Published var compact = false
    @Published var networkPreviews: Bool { didSet { if usePreferences { configurationDefaults?.set(networkPreviews, forKey: "networkPreviews") }; LinkPreviewCache.shared.enabled = networkPreviews } }
    @Published var indexingImages = false
    @Published var ocrProgress = ""
    var draggingIDs: [UUID] = []
    var dragStartedAt = Date.distantPast
    var selectionAnchor: UUID?
    var undoItems: [ItemUndo] = []
    let ocrQueue = DispatchQueue(label: "openpaste.ocr", qos: .utility)
    @Published var retentionDays: Int { didSet { if usePreferences { configurationDefaults?.set(retentionDays, forKey: "retentionDays") }; prune(); save() } }
    @Published var currentClipID: UUID?
    @Published var captureNotice = ""
    private let saveGeneration = SaveGeneration()
    private(set) var storageCallbackGeneration = 0
    let persistenceQueue = DispatchQueue(label: "openpaste.persistence", qos: .utility)
    let captureQueue = DispatchQueue(label: "openpaste.image-capture", qos: .userInitiated)
    private var captureGeneration = 0
    private var pendingImages: [Int: PendingImageCapture] = [:]
    var pauseBoundaryPasteboard: () -> NSPasteboard = { .general }
    private var resumeBoundary: (name: NSPasteboard.Name, change: Int)?
    private var persistedPauseExpiryPending = false
    private var freezeInitialResume = false
    @Published var root: URL
    @Published var initialLoading = false
    @Published var changingDataDirectory = false
    @Published var directoryStatus = ""
    @Published var directoryProgress = ImportProgress(phase: "", completed: 0, total: 0)
    var syncBaseline = DataDirectory.baseline(Archive())
    var syncStamp = ""
    var initialDirectoryLoadFailed = false
    private var storageRetryInFlight = false
    var syncChecking = false
    var directoryMutation = 0
    var syncTimer: Timer?
    var limit: Int { didSet { if usePreferences { configurationDefaults?.set(limit, forKey: "historyLimit") }; if !applyingImport { prune(); save() } } }
    var ignored: String { didSet { if usePreferences { configurationDefaults?.set(ignored, forKey: "ignoredApps") } } }
    var timer: Timer?
    var deletedCurrentChange: Int?
    var deletedCurrentID: UUID?
    var change = NSPasteboard.general.changeCount
    private var observedCaptureSources: [NSPasteboard.Name: [Int: ClipboardCaptureSource]] = [:]
    let ephemeral: Bool
    let usePreferences: Bool
    private let configurationDefaults: UserDefaults?
    private let injectedDeviceID: String?
    private var deferredInitialStart: (source: ClipboardCaptureSource?, changeCount: Int?)?
    init(root: URL? = nil, ephemeral: Bool = false, defaults: UserDefaults? = nil, deviceID: String? = nil,
         loadHistoryAsynchronously: Bool = false,
         initialHistoryLoader: ((URL) throws -> SyncSnapshot)? = nil) {
        let persistsPreferences = root == nil && !ephemeral
        self.ephemeral = ephemeral
        self.usePreferences = persistsPreferences
        let configurationDefaults = defaults ?? (persistsPreferences ? AppEnvironment.current.defaults : nil)
        self.configurationDefaults = configurationDefaults
        self.injectedDeviceID = deviceID ?? (persistsPreferences ? nil : UUID().uuidString)
        storageLimitMB = max(200, configurationDefaults?.integer(forKey: "storageLimitMB") ?? 0)
        shortcutLabel = (configurationDefaults.map { GlobalShortcut.load(from: $0) } ?? .standard).label
        shelfShortcuts = ShelfShortcuts.load(from: configurationDefaults)
        networkPreviews = configurationDefaults?.object(forKey: "networkPreviews") as? Bool ?? true
        retentionDays = configurationDefaults?.integer(forKey: "retentionDays") ?? 0
        limit = configurationDefaults?.object(forKey: "historyLimit") as? Int ?? 1000
        ignored = configurationDefaults?.string(forKey: "ignoredApps") ?? "com.1password.1password\ncom.agilebits.onepassword7\ncom.bitwarden.desktop\ncom.apple.Passwords"
        let selectedRoot = root ?? (ephemeral ? DataDirectory.defaultRoot : configurationDefaults?.string(forKey: "dataDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? DataDirectory.defaultRoot)
        do { self.root = try AppEnvironment.current.validateDataRoot(selectedRoot) }
        catch { fatalError("OpenPaste data directory error: \(error.localizedDescription)") }
        if usePreferences, let configurationDefaults {
            pauseReasons.setRecordingAccepted(configurationDefaults.bool(forKey: "recordingAccepted"))
            pauseReasons.setUserPaused(RecordingPausePersistence(defaults: configurationDefaults).restore().isPaused)
            paused = pauseReasons.isPaused
        }
        let asynchronousInitialLoad = !ephemeral && loadHistoryAsynchronously
        if !ephemeral {
            do {
                try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                _ = try AppEnvironment.current.validateDataRoot(self.root)
                if asynchronousInitialLoad {
                    initialLoading = true
                    changingDataDirectory = true
                    directoryStatus = "正在读取历史…"
                    directoryProgress = ImportProgress(phase: "正在读取历史", completed: 0, total: 0)
                    pauseReasons.beginTemporaryPause()
                    paused = pauseReasons.isPaused
                } else {
                    let file = self.root.appendingPathComponent("history.json")
                    if DataDirectory.usesSync(self.root) || FileManager.default.fileExists(atPath: file.path) {
                        syncBaseline = try Self.loadInitialHistory(from: self.root)
                        archive = syncBaseline.archive
                        // A successful migration must survive a crash before preference updates.
                        storageLimitMB = max(storageLimitMB, (archive.clips.reduce(0) { $0 + $1.byteCount } + 1048575) / 1048576)
                        if limit != 0 { limit = max(limit, archive.clips.filter { $0.boards.isEmpty }.count) }
                        prune()
                    }
                }
            } catch {
                setRecordingLoadFailure(error.localizedDescription)
                if DataDirectory.isCloud(self.root) {
                    directoryStatus = "等待同步：\(error.localizedDescription)"; initialDirectoryLoadFailed = true
                    if let cached = try? DataDirectory.cached(self.root) { syncBaseline = cached; archive = cached.archive }
                }
            }
        }
        rebuildSources()
        refreshResults()
        if asynchronousInitialLoad, initialLoading {
            beginInitialHistoryLoad(using: initialHistoryLoader ?? Self.loadInitialHistory)
        }
    }
    private static func loadInitialHistory(from root: URL) throws -> SyncSnapshot {
        var snapshot = try DataDirectory.load(root)
        if DataDirectory.usesSync(root), let cached = try DataDirectory.cached(root) { snapshot = DataDirectory.merge(snapshot, cached) }
        return snapshot
    }
    private func beginInitialHistoryLoad(using loader: @escaping (URL) throws -> SyncSnapshot) {
        let folder = root
        let generation = directoryMutation
        persistenceQueue.async { [weak self] in
            let finishLoad = AcceptanceMetrics.begin("history.initial-load.background")
            let result = Result { try loader(folder) }
            let cached: SyncSnapshot?
            if case .failure = result, DataDirectory.isCloud(folder) { cached = try? DataDirectory.cached(folder) }
            else { cached = nil }
            finishLoad()
            DispatchQueue.main.async {
                guard let self, self.initialLoading, self.root.standardizedFileURL == folder.standardizedFileURL,
                      self.directoryMutation == generation else { return }
                let finishInstall = AcceptanceMetrics.begin("history.initial-install")
                defer { finishInstall() }
                var loaded = false
                switch result {
                case .success(let snapshot):
                    self.syncBaseline = snapshot
                    self.installLoadedArchive(snapshot.archive)
                    self.initialDirectoryLoadFailed = false
                    self.directoryStatus = DataDirectory.usesSync(folder) ? "已读取 iCloud 历史；上传与下载由系统完成。" : ""
                    loaded = true
                case .failure(let error):
                    if let cached {
                        self.syncBaseline = cached
                        self.installLoadedArchive(cached.archive)
                    }
                    self.setRecordingLoadFailure(error.localizedDescription)
                    self.directoryStatus = ""
                    if DataDirectory.isCloud(folder) {
                        self.directoryStatus = "等待同步：\(error.localizedDescription)"
                        self.initialDirectoryLoadFailed = true
                    }
                }
                self.initialLoading = false
                self.changingDataDirectory = false
                self.directoryProgress = ImportProgress(phase: "", completed: 0, total: 0)
                self.pauseReasons.endTemporaryPause()
                let freezeOnResume = self.freezeInitialResume || self.persistedPauseExpiryPending
                self.freezeInitialResume = false
                self.refreshPauseState(freezeOnResume: freezeOnResume)
                if loaded { self.resumeDeferredInitialStart() }
                else if self.initialDirectoryLoadFailed, self.deferredInitialStart != nil { self.ensureSyncTimer() }
            }
        }
    }
    func resumeDeferredInitialStart() {
        guard !initialLoading, !changingDataDirectory, !hasHistoryLoadFailure,
              let deferred = deferredInitialStart else { return }
        deferredInitialStart = nil
        start(initialSource: deferred.source, initialChangeCount: deferred.changeCount)
    }
    func deviceIDForPersistence() -> String {
        if let injectedDeviceID { return injectedDeviceID }
        guard let configurationDefaults else { return UUID().uuidString }
        return DataDirectory.deviceID(defaults: configurationDefaults)
    }
    func persistSelectedDataRoot() {
        if usePreferences { configurationDefaults?.set(root.path, forKey: "dataDirectory") }
    }
    var filtered: [Clip] { visibleClips }
    func visibleIndex(of id: UUID) -> Int? { visibleIndexByID[id] }
    var sources: [String] { sourceNames }
    private func filterValueChanged() {
        if batchingFilterChanges { filterRefreshPending = true }
        else { refreshResults() }
    }
    private func rebuildSources() {
        sourcePasses += 1
        sourceNames = Array(Set(archive.clips.map(\.source))).sorted()
    }
    /// Clears query, kind, source and today filters in one refresh. Board and the
    /// enabled date range are also cleared unless their preserve flags are set;
    /// stored start/end dates remain available for the next time the range is enabled.
    func resetFilters(preserveBoard: Bool = false, preserveDateRange: Bool = false) {
        batchingFilterChanges = true
        if !query.isEmpty { query = "" }
        if !preserveBoard, board != nil { board = nil }
        if kind != "全部" { kind = "全部" }
        if sourceFilter != "全部来源" { sourceFilter = "全部来源" }
        if todayOnly { todayOnly = false }
        if !preserveDateRange, dateRangeEnabled { dateRangeEnabled = false }
        batchingFilterChanges = false
        if filterRefreshPending { filterRefreshPending = false; refreshResults() }
    }
    private func refreshResults() {
        filterPasses += 1
        visibleClips = archive.clips.filter { c in
            (board == nil || c.boards.contains(board!)) && (kind == "全部" || c.kind == kind) &&
            (sourceFilter == "全部来源" || c.source == sourceFilter) && (!todayOnly || Calendar.current.isDateInToday(c.created)) && (!dateRangeEnabled || (c.created >= Calendar.current.startOfDay(for: startDate) && c.created < Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: endDate))!)) &&
            (query.isEmpty || c.title.localizedCaseInsensitiveContains(query) || c.text.localizedCaseInsensitiveContains(query) || c.source.localizedCaseInsensitiveContains(query) || (c.ocrText?.localizedCaseInsensitiveContains(query) ?? false) || (c.linkTitle?.localizedCaseInsensitiveContains(query) ?? false) || (c.userLabel?.localizedCaseInsensitiveContains(query) ?? false))
        }
        if reverseHistory { visibleClips.reverse() }
        visibleIndexByID.removeAll(keepingCapacity: true)
        for (index, clip) in visibleClips.enumerated() where visibleIndexByID[clip.id] == nil { visibleIndexByID[clip.id] = index }
        selection.formIntersection(Set(visibleIndexByID.keys))
        if selected.flatMap({ visibleIndexByID[$0] }) == nil { selected = visibleClips.first?.id }
    }
    func moveSelection(_ delta: Int) {
        guard !visibleClips.isEmpty else { return }
        let index = selected.flatMap { visibleIndexByID[$0] } ?? 0
        selection.removeAll()
        selected = visibleClips[max(0, min(visibleClips.count - 1, index + delta))].id; selectionAnchor = selected
    }
    func prune() {
        guard canModifyHistory else { return }
        pruneLoadedArchive()
    }
    private func prunedArchive(_ source: Archive) -> Archive {
        var result = source
        let cutoff = retentionDays > 0 ? Date().addingTimeInterval(-Double(retentionDays * 86400)) : nil
        var count = 0
        var bytes = result.clips.filter { !$0.boards.isEmpty }.reduce(0) { $0 + $1.byteCount }
        result.clips = result.clips.filter { clip in
            if !clip.boards.isEmpty { return true }
            if let cutoff, clip.created < cutoff { return false }
            count += 1
            bytes += clip.byteCount
            return (limit == 0 || count <= limit) && bytes <= maxArchiveBytes
        }
        return result
    }
    private func pruneLoadedArchive() {
        // Assigning archive publishes and re-filters all history; do it only if something was removed.
        let pruned = prunedArchive(archive)
        if pruned.clips.count != archive.clips.count { archive = pruned }
        discardMissingQueueItems()
    }
    func save() {
        guard !ephemeral, !initialLoading, !changingDataDirectory, !importingPaste, pauseReasons.loadFailure == nil else { return }
        directoryMutation += 1
        let snapshot = archive
        let undoClips = undoItems.flatMap(\.clips)
        let folder = root
        let cloud = DataDirectory.usesSync(folder)
        if cloud { syncBaseline = DataDirectory.changes(snapshot, from: syncBaseline) }
        let baseline = syncBaseline
        let device = cloud ? deviceIDForPersistence() : ""
        let mutation = directoryMutation
        let generation = saveGeneration.next()
        let gate = saveGeneration
        let url = root.appendingPathComponent("history.json")
        persistenceQueue.async { [weak self] in
            guard gate.isCurrent(generation) else { return }
            var savedBaseline: SyncSnapshot?
            do {
                if cloud {
                    try DataDirectory.cache(baseline, root: folder)
                    let merged = DataDirectory.merge(try DataDirectory.load(folder), DataDirectory.changes(snapshot, from: baseline))
                    try DataDirectory.write(merged, root: folder, device: device)
                    savedBaseline = merged
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
                DispatchQueue.main.async {
                    guard let self, gate.isCurrent(generation), self.root == folder, self.directoryMutation == mutation, !self.changingDataDirectory else { return }
                    if let savedBaseline {
                        self.syncBaseline = savedBaseline; self.archive = savedBaseline.archive
                        self.directoryStatus = "已保存到 iCloud 目录；上传与下载由系统完成。"
                    }
                    self.storageRetryInFlight = false
                    let recovered = self.pauseReasons.saveFailure != nil
                    self.setRecordingSaveFailure(nil)
                    if recovered { self.message = self.storageDescription }
                }
            } catch {
                let detail = error.localizedDescription
                DispatchQueue.main.async {
                    guard let self, gate.isCurrent(generation), self.root == folder, self.directoryMutation == mutation, !self.changingDataDirectory else { return }
                    self.storageRetryInFlight = false
                    if cloud { self.directoryStatus = "等待同步：\(detail)" }
                    self.setRecordingSaveFailure(detail)
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
        // Initial loading only reads history, while every mutation and save path is
        // gated. A termination flush therefore has no pending write to wait for.
        if !initialLoading { persistenceQueue.sync {} }
    }
    func start(initialSource: ClipboardCaptureSource? = nil, initialChangeCount: Int? = nil) {
        guard !ephemeral else { return }
        if initialLoading {
            deferredInitialStart = (initialSource, initialChangeCount)
            return
        }
        if hasHistoryLoadFailure {
            deferredInitialStart = (initialSource, initialChangeCount)
            if initialDirectoryLoadFailed { ensureSyncTimer() }
            return
        }
        let pasteboard = NSPasteboard.general
        let source = initialChangeCount == pasteboard.changeCount ? initialSource : nil
        capture(force: true, pasteboard: pasteboard, sourceOverride: source)
        ensureSyncTimer()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.capture() }
        if let timer = timer { RunLoop.main.add(timer, forMode: .common) }
    }
    private func ensureSyncTimer() {
        guard syncTimer == nil else { return }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.runSyncTimerAction() }
        if let syncTimer { RunLoop.main.add(syncTimer, forMode: .common) }
    }
    func runSyncTimerAction() {
        if hasHistoryLoadFailure {
            if initialDirectoryLoadFailed { retryRecordingStorage() }
            return
        }
        pollDirectory()
    }
    func setUserPaused(_ value: Bool) {
        if initialLoading, pauseReasons.userPaused, !value { freezeInitialResume = true }
        pauseReasons.setUserPaused(value)
        refreshPauseState()
    }
    func setRecordingAccepted(_ value: Bool) {
        pauseReasons.setRecordingAccepted(value)
        if usePreferences { configurationDefaults?.set(value, forKey: "recordingAccepted") }
        // First-time consent intentionally captures the current clipboard.
        refreshPauseState(freezeOnResume: false)
    }
    func setRecordingLoadFailure(_ detail: String?) {
        pauseReasons.setLoadFailure(detail)
        if let detail { message = "历史读取失败：\(detail)。修复数据后重试读取。" }
        refreshPauseState()
    }
    func setRecordingSaveFailure(_ detail: String?) {
        pauseReasons.setSaveFailure(detail)
        if let detail { message = "历史保存失败：\(detail)。内存中的更改仍保留，请修复后重试保存。" }
        refreshPauseState()
    }
    func retryRecordingStorage() {
        guard !ephemeral, !storageRetryInFlight, !changingDataDirectory, !importingPaste else { return }
        if pauseReasons.loadFailure != nil {
            storageRetryInFlight = true
            let folder = root, mutation = directoryMutation
            persistenceQueue.async { [weak self] in
                let result = Result { () throws -> SyncSnapshot in
                    var snapshot = try DataDirectory.load(folder)
                    if DataDirectory.usesSync(folder), let cached = try DataDirectory.cached(folder) { snapshot = DataDirectory.merge(snapshot, cached) }
                    return snapshot
                }
                DispatchQueue.main.async {
                    guard let self, self.root == folder, self.directoryMutation == mutation, !self.changingDataDirectory else { return }
                    self.storageRetryInFlight = false
                    switch result {
                    case .success(let snapshot):
                        self.syncBaseline = snapshot
                        self.installLoadedArchive(snapshot.archive)
                        self.initialDirectoryLoadFailed = false
                        self.setRecordingLoadFailure(nil)
                        self.message = self.storageDescription
                        self.directoryStatus = DataDirectory.usesSync(folder) ? "已读取 iCloud 历史；上传与下载由系统完成。" : ""
                        self.resumeDeferredInitialStart()
                    case .failure(let error): self.setRecordingLoadFailure(error.localizedDescription)
                    }
                }
            }
        } else if pauseReasons.saveFailure != nil {
            storageRetryInFlight = true
            save()
        }
    }
    func installLoadedArchive(_ loaded: Archive) {
        applyingImport = true
        defer { applyingImport = false }
        undoItems.removeAll()
        currentClipID = nil
        deletedCurrentChange = nil
        deletedCurrentID = nil
        storageLimitMB = max(storageLimitMB, (loaded.clips.reduce(0) { $0 + $1.byteCount } + 1048575) / 1048576)
        if limit != 0 { limit = max(limit, loaded.clips.filter { $0.boards.isEmpty }.count) }
        archive = prunedArchive(loaded)
        discardMissingQueueItems()
    }
    func persistStorageLimitPreference() {
        if usePreferences { configurationDefaults?.set(storageLimitMB, forKey: "storageLimitMB") }
    }
    func invalidatePendingStorageCallbacks() {
        directoryMutation += 1
        storageCallbackGeneration += 1
        _ = saveGeneration.next()
        storageRetryInFlight = false
    }
    func beginTemporaryPause() {
        pauseReasons.beginTemporaryPause()
        refreshPauseState()
    }
    func endTemporaryPause() {
        pauseReasons.endTemporaryPause()
        refreshPauseState()
    }
    func freezeCurrentPasteboardRevision(_ pasteboard: NSPasteboard? = nil) {
        let pasteboard = pasteboard ?? pauseBoundaryPasteboard()
        change = pasteboard.changeCount
        resumeBoundary = (pasteboard.name, change)
        persistedPauseExpiryPending = false
        currentClipID = nil
        deletedCurrentChange = nil
        deletedCurrentID = nil
    }
    func notePersistedPauseExpired() {
        persistedPauseExpiryPending = true
        if !paused { freezeCurrentPasteboardRevision() }
    }
    private func refreshPauseState(freezeOnResume: Bool = true) {
        let wasPaused = paused
        paused = pauseReasons.isPaused
        if freezeOnResume, !paused, wasPaused || persistedPauseExpiryPending { freezeCurrentPasteboardRevision() }
    }
    func capture(force: Bool = false, pasteboard pb: NSPasteboard = .general, sourceOverride: ClipboardCaptureSource? = nil) {
        guard !selectionCaptureActive else { return }
        let observedChange = pb.changeCount
        let changed = observedChange != change
        guard !paused, force || changed else { return }
        if let boundary = resumeBoundary, boundary.name == pb.name {
            if boundary.change == observedChange { return }
            resumeBoundary = nil
        }
        let source = captureSource(for: pb, changeCount: observedChange, changed: changed, override: sourceOverride)
        if deletedCurrentChange == observedChange { return }
        if deletedCurrentChange != nil { deletedCurrentChange = nil; deletedCurrentID = nil }
        if force, observedChange == change, pendingImages[captureGeneration] != nil { return }
        if force, observedChange == change, let id = currentClipID, archive.clips.contains(where: { $0.id == id }) { return }
        change = observedChange
        captureContents(pb, source: source.name, sourceID: source.bundleID, backgroundImages: true, preserveExisting: force)
    }
    private func captureSource(for pasteboard: NSPasteboard, changeCount: Int, changed: Bool, override: ClipboardCaptureSource?) -> ClipboardCaptureSource {
        if let source = observedCaptureSources[pasteboard.name]?[changeCount] { return source }
        let app = NSWorkspace.shared.frontmostApplication
        let source = override ?? ClipboardCaptureSource(name: changed ? app?.localizedName ?? "未知应用" : "当前剪贴板", bundleID: app?.bundleIdentifier ?? "")
        rememberCaptureSource(source, for: pasteboard, changeCount: changeCount)
        return source
    }
    private func rememberCaptureSource(_ source: ClipboardCaptureSource, for pasteboard: NSPasteboard, changeCount: Int) {
        var sources = observedCaptureSources[pasteboard.name] ?? [:]
        sources[changeCount] = source
        if sources.count > 64 {
            for key in sources.keys.sorted().prefix(sources.count - 64) { sources.removeValue(forKey: key) }
        }
        observedCaptureSources[pasteboard.name] = sources
    }
    func recordRestoredClipboardChange(from originalChangeCount: Int, pasteboard: NSPasteboard = .general) {
        let restoredChangeCount = pasteboard.changeCount
        if let source = observedCaptureSources[pasteboard.name]?[originalChangeCount] {
            rememberCaptureSource(source, for: pasteboard, changeCount: restoredChangeCount)
        }
        change = restoredChangeCount
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
        guard canModifyHistory else { return nil }
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
        items.append(new); items.sort { $0.created > $1.created }
        // One assignment: prune before publishing instead of publishing, then pruning and publishing again.
        archive = prunedArchive(Archive(clips: items, boards: archive.boards))
        discardMissingQueueItems(); save()
        if new.kind == "链接", networkPreviews, !ephemeral { enrichLink(new) }
        return new.id
    }
    func delete(_ id: UUID, recordUndo: Bool = true) {
        guard canModifyHistory else { return }
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
        pasteQueue.removeAll { $0 == id }
        if wasSelected, let index = index { let remaining = filtered; selected = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id }
        save()
    }
    func pin(_ clip: Clip, to board: UUID) {
        guard canModifyHistory, let i = archive.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        if archive.clips[i].boards.contains(board) { archive.clips[i].boards.removeAll { $0 == board } } else { archive.clips[i].boards.append(board) }; save()
    }
    func addBoard(_ name: String) { let name = name.trimmingCharacters(in: .whitespacesAndNewlines); guard canModifyHistory, !name.isEmpty else { return }; archive.boards.append(Board(name: name)); save() }
    func setBoardColor(_ id: UUID, color: String) { guard canModifyHistory, let i = archive.boards.firstIndex(where: { $0.id == id }) else { return }; archive.boards[i].color = color; save() }
    func renameBoard(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canModifyHistory, !name.isEmpty, let i = archive.boards.firstIndex(where: { $0.id == id }), archive.boards[i].name != name else { return }
        archive.boards[i].name = name; save()
    }
    func removeBoard(_ id: UUID) { guard canModifyHistory else { return }; archive.boards.removeAll { $0.id == id }; for i in archive.clips.indices { archive.clips[i].boards.removeAll { $0 == id } }; if board == id { board = nil }; prune(); save() }
    func clearHistory() {
        guard canModifyHistory else { return }
        if let id = currentClipID, archive.clips.contains(where: { $0.id == id && $0.boards.isEmpty }) {
            deletedCurrentChange = change; deletedCurrentID = id; currentClipID = nil
        }
        archive.clips.removeAll { $0.boards.isEmpty }; discardMissingQueueItems(); save()
    }
    func restore(_ clip: Clip, plain: Bool, pasteboard pb: NSPasteboard = .general) -> Bool {
        let objects: [NSPasteboardItem]
        if plain {
            guard !clip.text.isEmpty, clip.kind != "图片", clip.kind != "文件" else { return false }
            let p = NSPasteboardItem(); p.setString(clip.text, forType: .string); objects = [p]
        } else {
            objects = clip.exportParts().map { parts in let p = NSPasteboardItem(); for part in parts { p.setData(part.data, forType: NSPasteboard.PasteboardType(part.type)) }; return p }
        }
        let originalChangeCount = pb.changeCount
        let outcome = ClipboardWrite.attempt(objects, to: pb)
        let ok = outcome.succeeded
        if outcome == .restoredPrevious { recordRestoredClipboardChange(from: originalChangeCount, pasteboard: pb) }
        else if outcome != .superseded { change = pb.changeCount }
        currentClipID = ok && archive.clips.contains(where: { $0.id == clip.id }) ? clip.id : nil
        if ok { recordUse([clip]) }
        return ok
    }
    func recordUse(_ clips: [Clip]) {
        guard canModifyHistory else { return }
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
        guard canModifyHistory else { return }
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
