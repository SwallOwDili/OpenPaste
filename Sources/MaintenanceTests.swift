import AppKit

func runMaintenanceTests() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("OpenPaste-maintenance-\(UUID())")
    defer { try? fm.removeItem(at: root) }
    var checks = 0
    func check(_ value: Bool, _ label: String) {
        guard value else { print("FAIL: \(label)"); exit(1) }
        checks += 1
    }
    func clip(_ text: String) -> Clip {
        Clip(source: "Fixture", sourceID: "fixture", kind: "文字", title: text, text: text, parts: [[ClipPart(type: "public.utf8-plain-text", data: Data(text.utf8))]])
    }
    func clean(_ cache: LinkPreviewCache, limit: Int? = nil) {
        let done = DispatchSemaphore(value: 0)
        cache.diskQueue.async { if let limit { cache.maxDiskBytes = limit }; cache.cleanDisk(); done.signal() }
        done.wait()
    }
    func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    do {
        let history = root.appendingPathComponent("history.json")
        let a = clip("attachment A"), b = clip("attachment B")
        let aFile = root.appendingPathComponent("blobs/\(HistoryStorage.digest(a.parts[0][0].data))")
        let bFile = root.appendingPathComponent("blobs/\(HistoryStorage.digest(b.parts[0][0].data))")
        try HistoryStorage.write(Archive(clips: [a, b]), to: history)
        try HistoryStorage.write(Archive(clips: [b]), to: history)
        try HistoryStorage.collectUnused(at: root, preserving: [a])
        check(fm.fileExists(atPath: aFile.path), "undo attachment retained")
        try HistoryStorage.collectUnused(at: root)
        check(!fm.fileExists(atPath: aFile.path) && fm.fileExists(atPath: bFile.path), "unreferenced attachment removed, live content retained")
        try HistoryStorage.write(Archive(clips: [a]), to: root.appendingPathComponent("device-other.json"))
        try HistoryStorage.collectUnused(at: root)
        check(fm.fileExists(atPath: aFile.path), "other device references retained")
        try fm.removeItem(at: root.appendingPathComponent("device-other.json"))
        try HistoryStorage.collectUnused(at: root, grace: 7 * 86400)
        check(fm.fileExists(atPath: aFile.path), "cloud upload grace retained")
        try Data("broken".utf8).write(to: root.appendingPathComponent("device-broken.json"))
        do { try HistoryStorage.collectUnused(at: root); check(false, "broken manifest fails closed") } catch { check(fm.fileExists(atPath: aFile.path), "broken manifest prevents deletion") }
        try fm.removeItem(at: root.appendingPathComponent("device-broken.json"))
        try HistoryStorage.collectUnused(at: root, now: Date().addingTimeInterval(8 * 86400), grace: 7 * 86400)
        check(!fm.fileExists(atPath: aFile.path), "expired cloud orphan collected")
        try HistoryStorage.write(Archive(clips: [a]), to: history)
        let version = root.appendingPathComponent("conflict-fixture.json")
        try fm.copyItem(at: history, to: version)
        try HistoryStorage.write(Archive(clips: [b]), to: history)
        try HistoryStorage.collectUnused(at: root, conflicts: { $0.lastPathComponent == "history.json" ? [version] : [] })
        check(fm.fileExists(atPath: aFile.path), "conflict version keeps otherwise deleted attachment")
        try fm.removeItem(at: version)
        for name in ["history.json", "device-offline.json", "before-directory-change-fixture.json", "before-paste-import-fixture.json"] {
            let placeholder = root.appendingPathComponent("." + name + ".icloud")
            try Data().write(to: placeholder)
            do { try HistoryStorage.collectUnused(at: root); check(false, "placeholder blocks collection") }
            catch { check(fm.fileExists(atPath: aFile.path), "undownloaded manifest/backup blocks collection") }
            try fm.removeItem(at: placeholder)
        }
        try Data("unrelated settings".utf8).write(to: root.appendingPathComponent("settings.json"))
        try HistoryStorage.collectUnused(at: root)
        check(!fm.fileExists(atPath: aFile.path) && fm.fileExists(atPath: bFile.path), "unrelated JSON does not disable collection")
        let backup = root.appendingPathComponent("before-paste-import-fixture.json")
        try HistoryStorage.write(Archive(clips: [a]), to: backup)
        try HistoryStorage.collectUnused(at: root)
        check(fm.fileExists(atPath: aFile.path), "managed import backup protects attachments")
        try fm.removeItem(at: backup)
        let live = Store(root: root)
        live.delete(b.id); live.flush()
        check(fm.fileExists(atPath: bFile.path), "Store deletion retains undo bytes")
        live.undoItemChange(); live.flush()
        check(try HistoryStorage.read(from: history).clips.first?.parts[0][0].data == b.parts[0][0].data, "undo restores readable bytes")
        live.delete(b.id); live.undoItems.removeAll(); live.save(); live.flush()
        check(!fm.fileExists(atPath: bFile.path), "discarding undo releases attachment")

        let shared = root.appendingPathComponent("shared")
        let orphanManifest = shared.appendingPathComponent("history.json")
        try HistoryStorage.write(Archive(clips: [a]), to: orphanManifest)
        try fm.removeItem(at: orphanManifest)
        let orphan = shared.appendingPathComponent("blobs/\(HistoryStorage.digest(a.parts[0][0].data))")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86400)], ofItemAtPath: orphan.path)
        try DataDirectory.write(DataDirectory.baseline(Archive()), root: shared, device: "fixture")
        defer { try? fm.removeItem(at: DataDirectory.cacheURL(shared).deletingLastPathComponent()) }
        let sharedStore = Store(root: shared)
        sharedStore.ingest(b); sharedStore.flush()
        check(fm.fileExists(atPath: orphan.path), "shared old orphan retained for unknown offline references")
        let localCacheRoot = DataDirectory.cacheURL(shared).deletingLastPathComponent()
        let localOrphan = localCacheRoot.appendingPathComponent("blobs/\(HistoryStorage.digest(a.parts[0][0].data))")
        try a.parts[0][0].data.write(to: localOrphan)
        sharedStore.save(); sharedStore.flush()
        check(!fm.fileExists(atPath: localOrphan.path) && fm.fileExists(atPath: orphan.path), "local sync cache collected without deleting shared attachment")

        let cache = LinkPreviewCache(root: root.appendingPathComponent("preview"))
        try fm.createDirectory(at: cache.root, withIntermediateDirectories: true)
        let key = "https://example.com/page"
        let result = LinkPreviewResult(title: "fresh", subtitle: "example.com")
        var cancelled = 0, callbacks = 0
        let first = PreviewRequest(); first.usesNetworkSlot = true; first.add { cancelled += 1 }
        cache.requests[key] = first; cache.pending[key] = [{ _ in callbacks += 1 }]; cache.active = 1
        cache.finish(key, result, request: first); drain()
        check(cancelled == 1 && callbacks == 1 && cache.active == 0, "completion cancels work and releases slot once")
        let json = cache.root.appendingPathComponent(cache.fileKey(key)).appendingPathExtension("json")
        cache.diskQueue.sync {}
        check(fm.fileExists(atPath: json.path), "successful preview saved")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)], ofItemAtPath: json.path)
        clean(cache)
        check(!fm.fileExists(atPath: json.path), "expired preview removed")
        let second = PreviewRequest(); second.usesNetworkSlot = true; second.add { cancelled += 1 }
        cache.requests[key] = second; cache.pending[key] = [{ _ in callbacks += 1 }]; cache.active = 1
        cache.finish(key, nil, request: first); drain()
        check(cache.active == 1 && callbacks == 1, "old timeout cannot finish new request")
        cache.finish(key, nil, request: second); drain()
        cache.finish(key, result, request: second); drain()
        check(cache.active == 0 && callbacks == 2 && cancelled == 2, "timeout cancels and ignores late completion")
        let third = PreviewRequest(); third.usesNetworkSlot = true; third.add { cancelled += 1 }
        cache.requests[key] = third; cache.pending[key] = [{ _ in callbacks += 1 }]; cache.active = 1
        cache.enabled = false
        check(third.cancelled && cache.active == 0 && callbacks == 3, "disable cancels active previews")
        third.add { cancelled += 1 }
        check(cancelled == 4, "late child task cancelled immediately")
        for i in 0..<3 {
            let file = cache.root.appendingPathComponent("entry-\(i).json")
            try Data(repeating: 1, count: 10).write(to: file)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(Double(i) - 10)], ofItemAtPath: file.path)
        }
        clean(cache, limit: 20)
        check(!fm.fileExists(atPath: cache.root.appendingPathComponent("entry-0.json").path) && fm.fileExists(atPath: cache.root.appendingPathComponent("entry-2.json").path), "disk cap evicts oldest preview")
        let hitCache = LinkPreviewCache(root: root.appendingPathComponent("cache-hit"))
        try fm.createDirectory(at: hitCache.root, withIntermediateDirectories: true)
        let hitFile = hitCache.root.appendingPathComponent(hitCache.fileKey(key)).appendingPathExtension("json")
        try JSONEncoder().encode(LinkPreviewCache.Saved(title: "disk hit", subtitle: "fixture")).write(to: hitFile)
        let oldDate = Date().addingTimeInterval(-3600)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: hitFile.path)
        hitCache.active = 2 // Simulate two slow in-flight network requests.
        var hitFinished = false
        hitCache.load(key) { value in check(value?.title == "disk hit" && Thread.isMainThread, "background cache read delivers to UI thread"); hitFinished = true }
        let deadline = Date().addingTimeInterval(2)
        while !hitFinished && Date() < deadline { drain() }
        check(hitFinished && hitCache.active == 2 && hitCache.jobs.isEmpty, "disk hit bypasses saturated network slots")
        hitCache.diskQueue.sync {}
        let unchanged = try hitFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        check(abs(unchanged.timeIntervalSince(oldDate)) < 1, "disk hit does not reset expiry")
        var sentEvents = 0, counted = 0
        let failed = PasteShortcut.send(makeEvent: { _ in nil }, post: { _ in sentEvents += 1 }, didSend: { counted += 1 })
        check(!failed && sentEvents == 0 && counted == 0, "failed shortcut does not count a paste")
        let sent = PasteShortcut.send(makeEvent: { CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: $0) }, post: { _ in sentEvents += 1 }, didSend: { check(sentEvents == 2, "count only after both events sent"); counted += 1 })
        check(sent && sentEvents == 2 && counted == 1, "successful shortcut counts once")
        print("Maintenance: \(checks) checks passed")
    } catch { print("FAIL: \(error)"); exit(1) }
}
