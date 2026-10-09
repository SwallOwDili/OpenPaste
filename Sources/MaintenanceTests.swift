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

        // A dangling blob symlink must be replaced, even when its own size equals the payload size.
        let linkRoot = root.appendingPathComponent("dangling-link")
        let linked = clip("dangling link attachment")
        let linkedBlob = linkRoot.appendingPathComponent("blobs/\(HistoryStorage.digest(linked.parts[0][0].data))")
        try fm.createDirectory(at: linkedBlob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: linkedBlob.path, withDestinationPath: String(repeating: "t", count: linked.parts[0][0].data.count))
        try HistoryStorage.write(Archive(clips: [linked]), to: linkRoot.appendingPathComponent("history.json"))
        check(try HistoryStorage.read(from: linkRoot.appendingPathComponent("history.json")).clips.first?.parts[0][0].data == linked.parts[0][0].data, "dangling attachment symlink is replaced and readable")
        let wrongSizeBlob = linkRoot.appendingPathComponent("blobs/\(HistoryStorage.digest(clip("wrong size").parts[0][0].data))")
        try Data("short".utf8).write(to: wrongSizeBlob)
        do { try HistoryStorage.write(Archive(clips: [clip("wrong size")]), to: linkRoot.appendingPathComponent("history.json")); check(false, "existing attachment with a different size is rejected") }
        catch { check(true, "existing attachment with a different size is rejected") }

        // Write and read share one attachment rule: regular file, inside blobs, expected size.
        let outside = clip("outside attachment!!")
        let outsideTarget = linkRoot.appendingPathComponent("outside-target")
        try outside.parts[0][0].data.write(to: outsideTarget)
        let outsideBlob = linkRoot.appendingPathComponent("blobs/\(HistoryStorage.digest(outside.parts[0][0].data))")
        try fm.createSymbolicLink(atPath: outsideBlob.path, withDestinationPath: outsideTarget.path)
        do { try HistoryStorage.write(Archive(clips: [outside]), to: linkRoot.appendingPathComponent("history.json")); check(false, "valid symlink to a file outside blobs is rejected on write") }
        catch { check(true, "valid symlink to a file outside blobs is rejected on write") }
        let readRoot = root.appendingPathComponent("outside-link-read")
        try fm.createDirectory(at: readRoot.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try HistoryStorage.write(Archive(clips: [outside]), to: readRoot.appendingPathComponent("history.json"))
        let readBlob = readRoot.appendingPathComponent("blobs/\(HistoryStorage.digest(outside.parts[0][0].data))")
        try fm.removeItem(at: readBlob)
        try fm.createSymbolicLink(atPath: readBlob.path, withDestinationPath: outsideTarget.path)
        do { _ = try HistoryStorage.read(from: readRoot.appendingPathComponent("history.json")); check(false, "valid symlink to a file outside blobs is rejected on read") }
        catch { check(true, "valid symlink to a file outside blobs is rejected on read") }
        let directoryBlob = linkRoot.appendingPathComponent("blobs/\(HistoryStorage.digest(clip("directory blob").parts[0][0].data))")
        try fm.createDirectory(at: directoryBlob, withIntermediateDirectories: true)
        do { try HistoryStorage.write(Archive(clips: [clip("directory blob")]), to: linkRoot.appendingPathComponent("history.json")); check(false, "a directory in place of an attachment is rejected") }
        catch { check(true, "a directory in place of an attachment is rejected") }
        let insideTarget = linkRoot.appendingPathComponent("blobs/inside-target")
        let inside = clip("inside link payload")
        try inside.parts[0][0].data.write(to: insideTarget)
        let insideBlob = linkRoot.appendingPathComponent("blobs/\(HistoryStorage.digest(inside.parts[0][0].data))")
        try fm.createSymbolicLink(atPath: insideBlob.path, withDestinationPath: insideTarget.path)
        try HistoryStorage.write(Archive(clips: [inside]), to: linkRoot.appendingPathComponent("history.json"))
        check(try HistoryStorage.read(from: linkRoot.appendingPathComponent("history.json")).clips.first?.parts[0][0].data == inside.parts[0][0].data, "symlink resolving inside blobs is accepted by write and read")

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

        let encodeStarted = DispatchSemaphore(value: 0), allowEncode = DispatchSemaphore(value: 0)
        var encodedOffMain = false, encodeCount = 0
        let cache = LinkPreviewCache(root: root.appendingPathComponent("preview"), imageEncoder: { _ in
            encodedOffMain = !Thread.isMainThread; encodeCount += 1
            encodeStarted.signal(); allowEncode.wait()
            return Data("fixture png".utf8)
        })
        try fm.createDirectory(at: cache.root, withIntermediateDirectories: true)
        let key = "https://example.com/page"
        let result = LinkPreviewResult(title: "fresh", subtitle: "example.com", image: NSImage(size: NSSize(width: 2, height: 2)))
        var cancelled = 0, callbacks = 0
        let first = PreviewRequest(); first.usesNetworkSlot = true; first.add { cancelled += 1 }
        cache.requests[key] = first; cache.pending[key] = [{ _ in callbacks += 1 }]; cache.active = 1
        var nextStarted = false
        cache.jobs.append(("next", { nextStarted = true; cache.active += 1 }))
        cache.finish(key, result, request: first); drain()
        check(encodeStarted.wait(timeout: .now() + 1) == .success, "successful preview starts background encoding")
        check(encodedOffMain && cancelled == 1 && callbacks == 1 && nextStarted && cache.active == 1, "encoding leaves UI thread and releases network slot")
        cache.active = 0; allowEncode.signal()
        let json = cache.root.appendingPathComponent(cache.fileKey(key)).appendingPathExtension("json")
        cache.imageQueue.sync {}
        cache.diskQueue.sync {}
        let firstSaved = try JSONDecoder().decode(LinkPreviewCache.Saved.self, from: Data(contentsOf: json))
        let png = cache.root.appendingPathComponent(firstSaved.imageFile!)
        let savedPNG = try Data(contentsOf: png)
        check(fm.fileExists(atPath: json.path) && savedPNG == Data("fixture png".utf8), "successful preview saved after background encoding")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)], ofItemAtPath: json.path)
        clean(cache)
        check(!fm.fileExists(atPath: json.path), "expired preview removed")
        cache.results.removeValue(forKey: key); cache.savedAt.removeValue(forKey: key)
        let second = PreviewRequest(); second.usesNetworkSlot = true; second.add { cancelled += 1 }
        cache.requests[key] = second; cache.pending[key] = [{ _ in callbacks += 1 }]; cache.active = 1
        cache.finish(key, nil, request: first); drain()
        cache.finish(key, result, request: first); drain()
        check(cache.active == 1 && callbacks == 1 && cache.results[key] == nil, "old generation cannot finish or cache over new request")
        cache.finish(key, nil, request: second); drain()
        cache.finish(key, result, request: second); drain()
        check(cache.active == 0 && callbacks == 2 && cancelled == 2, "timeout cancels and ignores late completion")
        cache.imageQueue.sync {}; cache.diskQueue.sync {}
        check(encodeCount == 1 && !fm.fileExists(atPath: json.path), "timed-out generation cannot encode or write a late result")

        let cancelledKey = "https://example.com/cancelled"
        let cancelledRequest = PreviewRequest(); cancelledRequest.usesNetworkSlot = true
        cache.requests[cancelledKey] = cancelledRequest; cache.pending[cancelledKey] = [{ _ in }]; cache.active = 1
        cache.finish(cancelledKey, result, request: cancelledRequest); drain()
        check(encodeStarted.wait(timeout: .now() + 1) == .success, "accepted preview begins asynchronous cache work")
        cache.enabled = false; allowEncode.signal()
        cache.imageQueue.sync {}; cache.diskQueue.sync {}
        let cancelledJSON = cache.root.appendingPathComponent(cache.fileKey(cancelledKey)).appendingPathExtension("json")
        check(encodeCount == 2 && !fm.fileExists(atPath: cancelledJSON.path) && cache.active == 0, "disable cancels pending cache write without holding network slot")
        cache.enabled = true
        let third = PreviewRequest(); third.usesNetworkSlot = true; third.add { cancelled += 1 }
        cache.requests[key] = third; cache.pending[key] = [{ _ in callbacks += 1 }]; cache.active = 1
        cache.enabled = false
        check(third.cancelled && cache.active == 0 && callbacks == 3, "disable cancels active previews")
        third.add { cancelled += 1 }
        check(cancelled == 4, "late child task cancelled immediately")
        cache.finish(key, result, request: third); drain()
        cache.imageQueue.sync {}; cache.diskQueue.sync {}
        check(encodeCount == 2 && !fm.fileExists(atPath: json.path), "cancelled request cannot write a late result")

        let beforeKey = "https://example.com/cancel-before-disk"
        let middleKey = "https://example.com/cancel-between-files"
        let beforeReached = DispatchSemaphore(value: 0), allowBefore = DispatchSemaphore(value: 0)
        let middleReached = DispatchSemaphore(value: 0), allowMiddle = DispatchSemaphore(value: 0)
        var middleImageWrites = 0, commitEncodeCount = 0
        let commitCache = LinkPreviewCache(root: root.appendingPathComponent("commit-races"), imageEncoder: { _ in
            commitEncodeCount += 1
            return Data("generation-\(commitEncodeCount)".utf8)
        }, writeHook: { stage, key in
            if key == beforeKey, stage == .beforeImage { beforeReached.signal(); allowBefore.wait() }
            if key == middleKey, stage == .imageWritten {
                middleImageWrites += 1
                if middleImageWrites == 2 { middleReached.signal(); allowMiddle.wait() }
            }
        })
        func finishForCommitTest(_ key: String, title: String) {
            let request = PreviewRequest(); request.usesNetworkSlot = true
            commitCache.requests[key] = request; commitCache.pending[key] = [{ _ in }]; commitCache.active = 1
            commitCache.finish(key, LinkPreviewResult(title: title, subtitle: "fixture", image: NSImage(size: NSSize(width: 2, height: 2))), request: request)
            drain()
        }
        finishForCommitTest(beforeKey, title: "cancel before disk")
        check(beforeReached.wait(timeout: .now() + 1) == .success, "cache write reaches controllable pre-commit boundary")
        let cancelStarted = Date(); commitCache.enabled = false
        check(Date().timeIntervalSince(cancelStarted) < 0.2, "cache cancellation does not wait for disk queue")
        allowBefore.signal(); commitCache.imageQueue.sync {}; commitCache.diskQueue.sync {}
        let beforeBase = commitCache.fileKey(beforeKey)
        let beforeFiles = (try? fm.contentsOfDirectory(at: commitCache.root, includingPropertiesForKeys: nil)) ?? []
        check(!beforeFiles.contains { $0.lastPathComponent.hasPrefix(beforeBase) }, "cancellation before disk commit leaves no generation files")

        commitCache.enabled = true
        finishForCommitTest(middleKey, title: "baseline generation")
        commitCache.imageQueue.sync {}; commitCache.diskQueue.sync {}
        let middleBase = commitCache.root.appendingPathComponent(commitCache.fileKey(middleKey))
        let middleJSON = middleBase.appendingPathExtension("json")
        let baseline = try JSONDecoder().decode(LinkPreviewCache.Saved.self, from: Data(contentsOf: middleJSON))
        let baselineImage = commitCache.root.appendingPathComponent(baseline.imageFile!)
        finishForCommitTest(middleKey, title: "old generation")
        check(middleReached.wait(timeout: .now() + 1) == .success, "cache write reaches PNG-before-metadata boundary")
        commitCache.enabled = false
        allowMiddle.signal(); commitCache.imageQueue.sync {}; commitCache.diskQueue.sync {}
        let preserved = try JSONDecoder().decode(LinkPreviewCache.Saved.self, from: Data(contentsOf: middleJSON))
        check(preserved.title == "baseline generation" && fm.fileExists(atPath: baselineImage.path), "mid-commit cancellation preserves the previous complete generation")
        commitCache.enabled = true
        finishForCommitTest(middleKey, title: "new generation")
        commitCache.imageQueue.sync {}; commitCache.diskQueue.sync {}
        let replacement = try JSONDecoder().decode(LinkPreviewCache.Saved.self, from: Data(contentsOf: middleJSON))
        let replacementImage = commitCache.root.appendingPathComponent(replacement.imageFile!)
        let middlePNGs = (try? fm.contentsOfDirectory(at: commitCache.root, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "png" && $0.lastPathComponent.hasPrefix(middleBase.lastPathComponent) } ?? []
        let middlePNGPaths = middlePNGs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }.sorted()
        let replacementPath = replacementImage.resolvingSymlinksInPath().standardizedFileURL.path
        let replacementBytes = try Data(contentsOf: replacementImage)
        check(replacement.title == "new generation" && replacementBytes == Data("generation-4".utf8) && middlePNGPaths == [replacementPath], "new same-key generation replaces a cancelled mid-commit write without orphan PNG")
        commitCache.enabled = false; commitCache.diskQueue.sync {}
        check(fm.fileExists(atPath: middleJSON.path) && fm.fileExists(atPath: replacementImage.path), "disabling network previews retains a completed disk cache")

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
