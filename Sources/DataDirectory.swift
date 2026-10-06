import AppKit

struct SyncRevision: Codable, Equatable {
    var time: Double
    var deleted: Bool
    var signature: String
}
struct SyncIndex: Codable {
    var clips: [String: SyncRevision] = [:]
    var boards: [String: SyncRevision] = [:]
}
struct SyncSnapshot {
    var archive: Archive
    var index: SyncIndex
}
enum DataDirectory {
    static var defaultRoot: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenPaste", isDirectory: true) }
    static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "dataDeviceID"), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString; UserDefaults.standard.set(id, forKey: "dataDeviceID"); return id
    }
    static func isCloud(_ root: URL) -> Bool {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents").path + "/"
        return root.standardizedFileURL.path.hasPrefix(cloud) || (try? root.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }
    static func cacheURL(_ root: URL) -> URL {
        defaultRoot.deletingLastPathComponent().appendingPathComponent("OpenPaste-sync-cache").appendingPathComponent(HistoryStorage.digest(Data(root.standardizedFileURL.path.utf8))).appendingPathComponent("history.json")
    }
    static func cached(_ root: URL) throws -> SyncSnapshot? {
        let url = cacheURL(root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let archive = try HistoryStorage.read(from: url)
        return SyncSnapshot(archive: archive, index: try HistoryStorage.syncIndex(from: url) ?? baseline(archive).index)
    }
    static func cache(_ snapshot: SyncSnapshot, root: URL) throws {
        try HistoryStorage.write(snapshot.archive, to: cacheURL(root), sync: snapshot.index)
    }
    static func ready(_ url: URL) throws {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw PasteImport.failure("iCloud 内容正在下载，请稍后重试")
        }
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]), values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus, status != .current {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw PasteImport.failure("iCloud 内容正在下载，请稍后重试")
        }
    }
    static func coordinated<T>(_ url: URL, writing: Bool, _ action: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let accessor: (URL) -> Void = { path in result = Result { try action(path) } }
        if writing { coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError, byAccessor: accessor) }
        else { coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor) }
        if let error = coordinationError { throw error }
        guard let result else { throw PasteImport.failure("无法访问数据目录") }
        return try result.get()
    }
    static func manifests(_ root: URL) throws -> [URL] {
        try ready(root)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        for file in files where file.lastPathComponent.hasPrefix(".device-") && file.lastPathComponent.hasSuffix(".json.icloud") {
            let name = String(file.lastPathComponent.dropFirst().dropLast(7))
            try ready(root.appendingPathComponent(name))
        }
        return files.filter { $0.lastPathComponent.hasPrefix("device-") && $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }
    static func usesSync(_ root: URL) -> Bool { isCloud(root) || ((try? manifests(root).isEmpty) == false) }
    static func stamp(_ root: URL) throws -> String {
        try manifests(root).map { url in
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(url.lastPathComponent):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
        }.joined(separator: "|")
    }
    static func clipSignature(_ clip: Clip) -> String {
        var metadata = clip; metadata.cachedDigest = clip.fingerprint; metadata.parts = []; metadata.boards.sort { $0.uuidString < $1.uuidString }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return HistoryStorage.digest((try? encoder.encode(metadata)) ?? Data())
    }
    static func boardSignature(_ board: Board) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return HistoryStorage.digest((try? encoder.encode(board)) ?? Data())
    }
    static func baseline(_ archive: Archive) -> SyncSnapshot {
        SyncSnapshot(archive: archive, index: SyncIndex(clips: Dictionary(archive.clips.map { ($0.id.uuidString, SyncRevision(time: 0, deleted: false, signature: clipSignature($0))) }, uniquingKeysWith: { a, _ in a }), boards: Dictionary(archive.boards.map { ($0.id.uuidString, SyncRevision(time: 0, deleted: false, signature: boardSignature($0))) }, uniquingKeysWith: { a, _ in a })))
    }
    static func newer(_ a: SyncRevision, _ b: SyncRevision) -> Bool {
        if a.time != b.time { return a.time > b.time }
        if a.deleted != b.deleted { return a.deleted }
        return a.signature > b.signature
    }
    static func merge(_ a: SyncSnapshot, _ b: SyncSnapshot) -> SyncSnapshot {
        var index = a.index
        var clips = Dictionary(a.archive.clips.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { x, _ in x })
        var boards = Dictionary(a.archive.boards.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { x, _ in x })
        let otherClips = Dictionary(b.archive.clips.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { x, _ in x })
        let otherBoards = Dictionary(b.archive.boards.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { x, _ in x })
        for (id, revision) in b.index.clips where index.clips[id].map({ newer(revision, $0) }) ?? true { index.clips[id] = revision; clips[id] = revision.deleted ? nil : otherClips[id] }
        for (id, revision) in b.index.boards where index.boards[id].map({ newer(revision, $0) }) ?? true { index.boards[id] = revision; boards[id] = revision.deleted ? nil : otherBoards[id] }
        let validBoards = Set(boards.values.map(\.id))
        let validClips: [Clip] = clips.values.map { item in
            var clip = item
            clip.boards.removeAll { !validBoards.contains($0) }
            return clip
        }
        let orderedClips = validClips.sorted { lhs, rhs in
            if lhs.created == rhs.created { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.created > rhs.created
        }
        return SyncSnapshot(archive: Archive(clips: orderedClips, boards: boards.values.sorted { $0.id.uuidString < $1.id.uuidString }), index: index)
    }
    static func equivalent(_ a: Clip, _ b: Clip) -> Bool {
        guard a.created == b.created, a.source == b.source, a.sourceID == b.sourceID, a.kind == b.kind, a.title == b.title, a.text == b.text, Set(a.boards) == Set(b.boards), a.ocrText == b.ocrText, a.userLabel == b.userLabel, a.linkTitle == b.linkTitle else { return false }
        if let first = a.cachedDigest, let second = b.cachedDigest { return first == second }
        return a.parts == b.parts
    }
    static func changes(_ archive: Archive, from baseline: SyncSnapshot, at time: Double = Date().timeIntervalSince1970) -> SyncSnapshot {
        var next = SyncSnapshot(archive: archive, index: baseline.index)
        let previousClips = Dictionary(baseline.archive.clips.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let previousBoards = Dictionary(baseline.archive.boards.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = Set(archive.clips.map { $0.id.uuidString }), boardIDs = Set(archive.boards.map { $0.id.uuidString })
        for clip in archive.clips {
            let id = clip.id.uuidString
            if let previous = previousClips[id], baseline.index.clips[id]?.deleted == false, equivalent(clip, previous) { continue }
            let signature = clipSignature(clip)
            if baseline.index.clips[id]?.signature != signature || baseline.index.clips[id]?.deleted == true { next.index.clips[id] = SyncRevision(time: max(time, (baseline.index.clips[id]?.time ?? 0) + 0.000001), deleted: false, signature: signature) }
        }
        for (id, revision) in baseline.index.clips where !revision.deleted && !ids.contains(id) { next.index.clips[id] = SyncRevision(time: max(time, revision.time + 0.000001), deleted: true, signature: "") }
        for board in archive.boards {
            let id = board.id.uuidString
            if let previous = previousBoards[id], baseline.index.boards[id]?.deleted == false, previous.name == board.name, previous.color == board.color { continue }
            let signature = boardSignature(board)
            if baseline.index.boards[id]?.signature != signature || baseline.index.boards[id]?.deleted == true { next.index.boards[id] = SyncRevision(time: max(time, (baseline.index.boards[id]?.time ?? 0) + 0.000001), deleted: false, signature: signature) }
        }
        for (id, revision) in baseline.index.boards where !revision.deleted && !boardIDs.contains(id) { next.index.boards[id] = SyncRevision(time: max(time, revision.time + 0.000001), deleted: true, signature: "") }
        return next
    }
    static func load(_ root: URL) throws -> SyncSnapshot {
        let files = try manifests(root)
        if files.isEmpty {
            let url = root.appendingPathComponent("history.json")
            try ready(url)
            return try FileManager.default.fileExists(atPath: url.path) ? baseline(HistoryStorage.read(from: url)) : baseline(Archive())
        }
        var snapshot = baseline(Archive())
        for file in files {
            let other = try coordinated(file, writing: false) { path -> SyncSnapshot in
                try ready(path)
                let archive = try HistoryStorage.read(from: path)
                return SyncSnapshot(archive: archive, index: try HistoryStorage.syncIndex(from: path) ?? baseline(archive).index)
            }
            snapshot = merge(snapshot, other)
            // iCloud may retain a conflicting version when a device identity was cloned.
            for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? [] {
                let archive = try HistoryStorage.read(from: version.url, contentRoot: root)
                snapshot = merge(snapshot, SyncSnapshot(archive: archive, index: try HistoryStorage.syncIndex(from: version.url) ?? baseline(archive).index))
            }
        }
        return snapshot
    }
    static func write(_ snapshot: SyncSnapshot, root: URL, device: String, progress: ((ImportProgress) -> Void)? = nil) throws {
        let url = root.appendingPathComponent("device-\(device).json")
        try coordinated(url, writing: true) { path in try HistoryStorage.write(snapshot.archive, to: path, phase: "保存同步历史", progress: progress, sync: snapshot.index) }
    }
    static func migrate(_ archive: Archive, from source: URL, to destination: URL, device: String, progress: ((ImportProgress) -> Void)? = nil) throws -> SyncSnapshot {
        let source = source.standardizedFileURL.resolvingSymlinksInPath(), destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard destination.path != source.path, !destination.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(destination.path + "/") else { throw PasteImport.failure("请选择独立的数据文件夹，不能使用当前目录或它的上级、子目录") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var existing = try load(destination)
        if usesSync(destination), let cached = try cached(destination) { existing = merge(existing, cached) }
        let local = changes(archive, from: baseline(Archive()))
        let merged = merge(existing, local)
        // The source remains a complete backup; also snapshot destination before changing it.
        let history = destination.appendingPathComponent("history.json")
        if FileManager.default.fileExists(atPath: history.path) { try FileManager.default.copyItem(at: history, to: destination.appendingPathComponent("before-directory-change-\(UUID()).json")) }
        let stagingManifest = destination.appendingPathComponent("migration-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: stagingManifest) }
        try HistoryStorage.write(merged.archive, to: stagingManifest, phase: "迁移历史与附件", progress: progress, sync: merged.index)
        let verified = try HistoryStorage.read(from: stagingManifest)
        guard verified.clips.count == merged.archive.clips.count else { throw PasteImport.failure("迁移校验失败") }
        let files = try manifests(destination)
        let shared = isCloud(destination) || !files.isEmpty
        if shared { try write(merged, root: destination, device: device); try cache(merged, root: destination) }
        else { try coordinated(history, writing: true) { path in try HistoryStorage.write(merged.archive, to: path) } }
        return SyncSnapshot(archive: verified, index: merged.index)
    }
}

extension Store {
    var storageDescription: String { DataDirectory.isCloud(root) ? "由 iCloud Drive 同步" : "保存在所选目录" }
    func chooseDataDirectory() {
        guard !changingDataDirectory, !importingPaste else { return }
        let picker = NSOpenPanel(); picker.title = "选择 OpenPaste 数据目录"; picker.prompt = "使用此目录"
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.canCreateDirectories = true; picker.allowsMultipleSelection = false; picker.directoryURL = root
        if let parent = Controller.shared.settingsWindow { picker.beginSheetModal(for: parent) { response in if response == .OK, let url = picker.url { self.changeDataDirectory(to: url) } } }
    }
    func changeDataDirectory(to destination: URL) {
        guard !ephemeral, !changingDataDirectory, !importingPaste else { return }
        // Finish capture while recording still has its previous state; then freeze migration.
        captureQueue.sync {}
        finishDirectoryCapture()
        changingDataDirectory = true
        let wasPaused = paused; paused = true
        directoryStatus = "正在迁移，原目录会保留…"
        directoryProgress = ImportProgress(phase: "准备迁移", completed: 0, total: archive.clips.count)
        let snapshot = archive, source = root, device = DataDirectory.deviceID
        persistenceQueue.async {
            let result = Result { try DataDirectory.migrate(snapshot, from: source, to: destination, device: device) { progress in DispatchQueue.main.async { self.directoryProgress = progress } } }
            DispatchQueue.main.async {
                switch result {
                case .success(let migrated):
                    self.root = destination.standardizedFileURL
                    self.syncBaseline = migrated
                    self.syncStamp = ""
                    self.installImportedArchive(migrated.archive)
                    if self.usePreferences { UserDefaults.standard.set(self.root.path, forKey: "dataDirectory") }
                    self.directoryStatus = "目录已切换，原目录保留为备份。" + (DataDirectory.isCloud(self.root) ? " iCloud 上传与下载由系统完成。" : "")
                    self.message = self.storageDescription
                case .failure(let error): self.directoryStatus = "切换失败：\(error.localizedDescription)。仍使用原目录。"
                }
                self.changingDataDirectory = false; self.paused = wasPaused
                self.save()
            }
        }
    }
    func pollDirectory() {
        guard !ephemeral, !changingDataDirectory, !importingPaste, !syncChecking, DataDirectory.usesSync(root) else { return }
        syncChecking = true
        let folder = root, local = archive, baseline = syncBaseline, generation = directoryMutation
        let previousStamp = syncStamp, retry = directoryStatus.hasPrefix("等待同步")
        persistenceQueue.async {
            let result = Result { () throws -> (SyncSnapshot, String)? in
                let stamp = try DataDirectory.stamp(folder)
                if stamp == previousStamp && !retry { return nil }
                let remote = try DataDirectory.load(folder)
                let merged = DataDirectory.merge(remote, DataDirectory.changes(local, from: baseline))
                if merged.index.clips != remote.index.clips || merged.index.boards != remote.index.boards { try DataDirectory.write(merged, root: folder, device: DataDirectory.deviceID) }
                try DataDirectory.cache(merged, root: folder)
                return (merged, try DataDirectory.stamp(folder))
            }
            DispatchQueue.main.async {
                defer { self.syncChecking = false }
                guard self.root == folder, !self.changingDataDirectory, self.directoryMutation == generation else { return }
                switch result {
                case .success(let update):
                    if let (snapshot, stamp) = update {
                        self.syncBaseline = snapshot; self.archive = snapshot.archive; self.syncStamp = stamp
                        if self.initialDirectoryLoadFailed {
                            self.installImportedArchive(snapshot.archive)
                            self.initialDirectoryLoadFailed = false; self.paused = false
                        }
                        self.directoryStatus = "已读取 iCloud 历史；上传与下载由系统完成。"
                    }
                case .failure(let error): self.directoryStatus = "等待同步：\(error.localizedDescription)"
                }
            }
        }
    }
}

func runDataDirectoryTests() {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("OpenPaste-directory-tests-\(UUID())")
    defer { try? fm.removeItem(at: sandbox) }
    var passed = 0
    func check(_ condition: Bool, _ label: String) {
        guard condition else { print("FAIL: \(label)"); exit(1) }
        passed += 1; print("PASS: \(label)")
    }
    func clip(_ text: String) -> Clip { Clip(source: "Fixture", sourceID: "test.fixture", kind: "文字", title: text, text: text, parts: [[ClipPart(type: "public.utf8-plain-text", data: Data(text.utf8))]]) }
    do {
        let source = sandbox.appendingPathComponent("original"), destination = sandbox.appendingPathComponent("chosen")
        let a = clip("源目录内容"), b = clip("目标目录已有内容")
        try HistoryStorage.write(Archive(clips: [a]), to: source.appendingPathComponent("history.json"))
        try HistoryStorage.write(Archive(clips: [b]), to: destination.appendingPathComponent("history.json"))
        let migrated = try DataDirectory.migrate(Archive(clips: [a]), from: source, to: destination, device: "A")
        check(migrated.archive.clips.count == 2, "迁移合并目标目录已有历史")
        check(try HistoryStorage.read(from: source.appendingPathComponent("history.json")).clips.count == 1, "源目录完整保留")
        check(try DataDirectory.load(destination).archive.clips.count == 2, "重新加载迁移目录")
        check(try fm.contentsOfDirectory(atPath: destination.path).contains { $0.hasPrefix("before-directory-change-") }, "目标原索引已备份")
        check(migrated.archive.clips.first { $0.id == a.id }?.parts.first?.first?.data == Data(a.text.utf8), "附件内容校验")
        do { _ = try DataDirectory.migrate(migrated.archive, from: source, to: source.appendingPathComponent("nested"), device: "A"); check(false, "拒绝嵌套目录") } catch { check(true, "拒绝嵌套目录") }
        let broken = sandbox.appendingPathComponent("broken")
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("invalid json".utf8).write(to: broken.appendingPathComponent("history.json"))
        do { _ = try DataDirectory.migrate(migrated.archive, from: source, to: broken, device: "A"); check(false, "失败不切换") } catch { check(try HistoryStorage.read(from: source.appendingPathComponent("history.json")).clips.count == 1, "目标损坏时原历史仍完好") }
        let shared = sandbox.appendingPathComponent("shared")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        let empty = DataDirectory.baseline(Archive())
        let board = Board(name: "收藏", color: "blue")
        var pinned = a; pinned.boards = [board.id]
        let deviceA = DataDirectory.changes(Archive(clips: [pinned], boards: [board]), from: empty, at: 10)
        let deviceB = DataDirectory.changes(Archive(clips: [b]), from: empty, at: 11)
        try DataDirectory.write(deviceA, root: shared, device: "A")
        try DataDirectory.write(deviceB, root: shared, device: "B")
        let both = try DataDirectory.load(shared)
        check(both.archive.clips.count == 2 && both.archive.boards.count == 1, "两台设备独立索引合并历史与收藏")
        let deleted = DataDirectory.changes(Archive(clips: [b], boards: []), from: both, at: 20)
        try DataDirectory.write(deleted, root: shared, device: "A")
        let afterDelete = try DataDirectory.load(shared)
        check(afterDelete.archive.clips.map(\.id) == [b.id] && afterDelete.archive.boards.isEmpty, "删除标记阻止旧设备恢复已删内容")
        let staleNew = clip("离线新增")
        var staleArchive = both.archive; staleArchive.clips.append(staleNew)
        let stale = DataDirectory.changes(staleArchive, from: both, at: 21)
        try DataDirectory.write(stale, root: shared, device: "B")
        let offline = try DataDirectory.load(shared)
        check(Set(offline.archive.clips.map(\.id)) == Set([b.id, staleNew.id]), "离线新增保留，同时不复活已删除条目")
        let undone = DataDirectory.changes(Archive(clips: [a, b, staleNew]), from: offline, at: 30)
        try DataDirectory.write(undone, root: shared, device: "A")
        check(try DataDirectory.load(shared).archive.clips.count == 3, "显式撤销可重新恢复条目")
        var edited = b; edited.text = "修改后的内容"; edited.userLabel = "重命名"
        let newer = DataDirectory.changes(Archive(clips: [edited, a, staleNew]), from: try DataDirectory.load(shared), at: 40)
        try DataDirectory.write(newer, root: shared, device: "B")
        check(try DataDirectory.load(shared).archive.clips.first { $0.id == b.id }?.userLabel == "重命名", "编辑与重命名传播")
        check(DataDirectory.merge(deviceA, deviceB).index.clips == DataDirectory.merge(deviceB, deviceA).index.clips, "合并顺序不影响结果")
        let live = Store(root: shared)
        let rapid = clip("快速复制再删除")
        live.ingest(rapid); live.delete(rapid.id); live.flush()
        check(try DataDirectory.load(shared).archive.clips.allSatisfy { $0.id != rapid.id }, "连续保存与快速删除不会复活条目")
        let cachedHistory = try DataDirectory.cached(shared)
        check(cachedHistory?.index.clips[rapid.id.uuidString]?.deleted == true, "离线缓存保留尚待上传的删除标记")
        let localRoot = sandbox.appendingPathComponent("store-original"), newRoot = sandbox.appendingPathComponent("store-new")
        let migratingStore = Store(root: localRoot); migratingStore.ingest(clip("真实迁移工作流")); migratingStore.flush()
        migratingStore.changeDataDirectory(to: newRoot)
        var deadline = Date().addingTimeInterval(8)
        while migratingStore.changingDataDirectory && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        migratingStore.flush()
        check(migratingStore.root.path == newRoot.path && !migratingStore.changingDataDirectory, "Store 异步迁移后切换目录")
        check(Store(root: newRoot).archive.clips.count == 1, "Store 重启读取新目录")
        migratingStore.changeDataDirectory(to: broken)
        deadline = Date().addingTimeInterval(8)
        while migratingStore.changingDataDirectory && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        migratingStore.flush()
        check(migratingStore.root.path == newRoot.path && migratingStore.directoryStatus.hasPrefix("切换失败"), "Store 迁移失败恢复原目录与状态")
        defer { try? fm.removeItem(at: DataDirectory.cacheURL(shared).deletingLastPathComponent()) }
        let benchmark = Archive(clips: (0..<7500).map { clip("性能测试 \($0)") })
        let benchmarkBaseline = DataDirectory.baseline(benchmark)
        let began = Date()
        _ = DataDirectory.changes(benchmark, from: benchmarkBaseline)
        print(String(format: "7500 条索引比较耗时 %.3f 秒", Date().timeIntervalSince(began)))
        let manifest = shared.appendingPathComponent("device-A.json")
        check(try HistoryStorage.syncIndex(from: manifest)?.clips[a.id.uuidString] != nil, "同步索引可持久化")
        let id = HistoryStorage.digest(a.parts[0][0].data)
        try fm.removeItem(at: shared.appendingPathComponent("blobs").appendingPathComponent(id))
        do { _ = try DataDirectory.load(shared); check(false, "缺失附件阻止覆盖") } catch { check(fm.fileExists(atPath: manifest.path), "缺失附件阻止空历史覆盖") }
        print("Data directory: \(passed) checks passed")
    } catch { print("FAIL: \(error)"); exit(1) }
}
