import Foundation

@MainActor
func runFilterTests() async {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { print("FAIL: \(label)"); exit(1) }
        checks += 1
        print("PASS: \(label)")
    }
    func settle(_ store: Store) async {
        let finished = await store.awaitLatestSearch(timeout: 10)
        check(finished, "latest asynchronous search settles")
    }
    func clip(_ title: String, kind: String, source: String, created: Date, boards: [UUID] = []) -> Clip {
        Clip(created: created, source: source, sourceID: "fixture.\(source.lowercased())", kind: kind, title: title, text: title, parts: [[ClipPart(type: "public.utf8-plain-text", data: Data(title.utf8))]], boards: boards)
    }

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    let board = UUID()
    let store = Store(ephemeral: true)
    let alpha = clip("needle alpha", kind: "文字", source: "Editor", created: today, boards: [board])
    let image = clip("needle image", kind: "图片", source: "Camera", created: yesterday, boards: [board])
    let unpinned = clip("needle unpinned", kind: "文字", source: "Editor", created: today)
    let other = clip("other text", kind: "文字", source: "Editor", created: today, boards: [board])
    store.archive.clips = [alpha, image, unpinned, other]

    await settle(store)
    check(store.sources == ["Camera", "Editor"], "archive builds sorted source names")
    let sourcePasses = store.sourcePasses
    store.board = board
    store.kind = "文字"
    store.sourceFilter = "Editor"
    store.todayOnly = true
    store.startDate = yesterday
    store.endDate = today
    store.dateRangeEnabled = true
    store.query = "needle"
    await settle(store)
    check(store.filtered.map(\.id) == [alpha.id], "combined board, kind, source, date and query filters intersect")
    check(store.sourcePasses == sourcePasses, "filter changes do not rebuild source names")

    let equalPasses = store.filterPasses
    store.query = store.query
    store.board = store.board
    store.kind = store.kind
    store.sourceFilter = store.sourceFilter
    store.todayOnly = store.todayOnly
    store.dateRangeEnabled = store.dateRangeEnabled
    store.startDate = store.startDate
    store.endDate = store.endDate
    store.reverseHistory = store.reverseHistory
    check(store.filterPasses == equalPasses, "equal filter assignments do not rescan history")

    let preservedPasses = store.filterPasses
    store.resetFilters(preserveBoard: true, preserveDateRange: true)
    await settle(store)
    check(store.filterPasses == preservedPasses + 1, "batched reset performs one filter pass")
    check(store.board == board && store.dateRangeEnabled && store.startDate == yesterday && store.endDate == today, "optional reset preserves board and explicit date range")
    check(store.query.isEmpty && store.kind == "全部" && store.sourceFilter == "全部来源" && !store.todayOnly, "reset clears all other filters")

    let clearPasses = store.filterPasses
    store.resetFilters()
    await settle(store)
    check(store.filterPasses == clearPasses + 1 && store.board == nil && !store.dateRangeEnabled, "default reset clears board and date range in one pass")
    let noOpPasses = store.filterPasses
    store.resetFilters()
    check(store.filterPasses == noOpPasses, "resetting default filters is a no-op")

    store.selection = [alpha.id, other.id]
    store.selected = alpha.id
    store.query = "missing value"
    await settle(store)
    check(store.filtered.isEmpty && store.selected == nil && store.selection.isEmpty, "no-result filter clears stale selection")
    store.resetFilters()
    await settle(store)
    check(store.filtered.count == 4 && store.selected == alpha.id, "clearing filters restores results and a valid selection")
    store.moveSelection(-1)
    check(store.selected == alpha.id, "navigation clamps at the first result")
    store.moveSelection(1)
    check(store.selected == image.id && store.selection.isEmpty && store.selectionAnchor == image.id, "navigation advances and resets multi-selection")
    store.selected = other.id
    store.moveSelection(1)
    check(store.selected == other.id, "navigation clamps at the last result")
    store.reverseHistory = true
    await settle(store)
    check(store.filtered.first?.id == other.id && store.selected == other.id, "reverse order rebuilds the visible index and selects its first result")
    store.moveSelection(1)
    check(store.selected == unpinned.id, "navigation follows reversed visible order")
    store.reverseHistory = false

    await settle(store)
    let updatedSourcePasses = store.sourcePasses
    store.archive.clips.append(clip("new source", kind: "文字", source: "Browser", created: today))
    await settle(store)
    check(store.sourcePasses == updatedSourcePasses + 1 && store.sources == ["Browser", "Camera", "Editor"], "archive change rebuilds source names once")

    let performance = Store(ephemeral: true)
    let clips = (0..<5_000).map { index in clip("Item \(index)", kind: "文字", source: "Fixture", created: today) }
    performance.archive.clips = clips
    await settle(performance)
    performance.selected = clips[0].id
    let passesBeforeNavigation = performance.filterPasses
    let start = CFAbsoluteTimeGetCurrent()
    for iteration in 0..<50_000 { performance.moveSelection((iteration / 5_000) % 2 == 0 ? 1 : -1) }
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    check(performance.selected == clips.first?.id && performance.filterPasses == passesBeforeNavigation, "5000-item navigation keeps cached results across repeated full traversals")
    check(elapsed < 1.0, String(format: "5000-item indexed navigation stays below 1 second (%.3f s)", elapsed))

    let install = Store(ephemeral: true)
    install.retentionDays = 1
    install.limit = 10
    install.storageLimitMB = 1
    let expired = clip("expired", kind: "文字", source: "Fixture", created: Date().addingTimeInterval(-2 * 86400))
    var favorite = expired
    favorite.id = UUID()
    favorite.boards = [UUID()]
    var large = clip("large", kind: "文字", source: "Fixture", created: today)
    large.parts = [[ClipPart(type: "public.data", data: Data(repeating: 1, count: 1_100_000))]]
    let loadedClips = clips + [expired, favorite, large]
    await settle(install)
    let sourcePassesBeforeInstall = install.sourcePasses
    let filterPassesBeforeInstall = install.filterPasses
    let mutationBeforeInstall = install.directoryMutation
    install.installLoadedArchive(Archive(clips: loadedClips, boards: []))
    await settle(install)
    check(install.sourcePasses == sourcePassesBeforeInstall + 1 && install.filterPasses == filterPassesBeforeInstall + 1, "loaded archive publishes one source and filter refresh")
    check(!install.archive.clips.contains(where: { $0.id == expired.id }) && install.archive.clips.contains(where: { $0.id == favorite.id }), "loaded archive retention removes expired history and preserves favorites")
    check(install.archive.clips.count == loadedClips.count - 1 && install.limit == loadedClips.filter { $0.boards.isEmpty }.count, "loaded archive expands the history limit before pruning saved records")
    check(install.storageLimitMB >= 2 && install.archive.clips.contains(where: { $0.id == large.id }), "loaded archive expands storage capacity before pruning saved records")
    check(install.directoryMutation == mutationBeforeInstall, "loaded archive capacity updates do not schedule a save")

    let ingestStore = Store(ephemeral: true)
    ingestStore.limit = 0
    ingestStore.archive.clips = (0..<500).map { clip("ingest \($0)", kind: "文字", source: "Fixture", created: today.addingTimeInterval(Double(-$0))) }
    await settle(ingestStore)
    let ingestPasses = ingestStore.filterPasses, ingestSources = ingestStore.sourcePasses
    ingestStore.ingest(clip("brand new", kind: "文字", source: "Fixture", created: today.addingTimeInterval(10)))
    await settle(ingestStore)
    check(ingestStore.filterPasses == ingestPasses + 1 && ingestStore.sourcePasses == ingestSources + 1 && ingestStore.archive.clips.count == 501, "ingest without pruning publishes the history once")
    ingestStore.limit = 100
    await settle(ingestStore)
    let cappedPasses = ingestStore.filterPasses
    ingestStore.ingest(clip("another new", kind: "文字", source: "Fixture", created: today.addingTimeInterval(20)))
    await settle(ingestStore)
    check(ingestStore.filterPasses == cappedPasses + 1 && ingestStore.archive.clips.count == 100, "ingest that prunes still publishes the history once")
    let untouchedPasses = ingestStore.filterPasses
    ingestStore.prune()
    check(ingestStore.filterPasses == untouchedPasses, "prune without removals does not republish the history")

    let ocrStore = Store(ephemeral: true)
    let ocrClips = (0..<3).map { clip("image \($0)", kind: "图片", source: "Fixture", created: today.addingTimeInterval(Double(-$0))) }
    ocrStore.archive.clips = ocrClips
    await settle(ocrStore)
    let ocrPasses = ocrStore.filterPasses
    let ocrSourcePasses = ocrStore.sourcePasses
    var stale = ocrClips[2]; stale.parts = [[ClipPart(type: "public.data", data: Data([9]))]]; stale.cachedDigest = nil
    let applied = ocrStore.applyRecognizedTexts([(ocrClips[0], "zero"), (ocrClips[1], "one"), (stale, "stale")], storageGeneration: ocrStore.storageCallbackGeneration)
    await settle(ocrStore)
    check(applied == 2 && ocrStore.filterPasses == ocrPasses + 1, "OCR results from one batch publish the history once and skip changed clips")
    check(ocrStore.sourcePasses == ocrSourcePasses, "OCR text-only batch does not rebuild unchanged source names")
    check(ocrStore.archive.clips[0].ocrText == "zero" && ocrStore.archive.clips[1].ocrText == "one" && ocrStore.archive.clips[2].ocrText == nil, "OCR batch writes text only to matching clips")

    check(ShelfRenderWindow.initialCount(total: 5_000) == 64 && ShelfRenderWindow.initialCount(total: 12) == 12, "shelf render window starts with at most 64 records")
    check(ShelfRenderWindow.nextCount(current: 64, total: 5_000) == 128 && ShelfRenderWindow.nextCount(current: 128, total: 150) == 150, "shelf render window grows by 64 and clamps to the result count")
    check(ShelfRenderWindow.countIncluding(index: 63, total: 5_000) == 64 && ShelfRenderWindow.countIncluding(index: 64, total: 5_000) == 128 && ShelfRenderWindow.countIncluding(index: 191, total: 5_000) == 192, "shelf render window includes keyboard selections at batch boundaries")
    check(ShelfRenderWindow.resetCount(total: 5_000, selectedIndex: nil) == 64 && ShelfRenderWindow.resetCount(total: 5_000, selectedIndex: 130) == 192, "shelf filter reset preserves an out-of-window selection")

    // Compare the new worker path with the original six-field predicate, including
    // non-ASCII case folding and matches beyond a card's truncated display text.
    let semantic = Store(ephemeral: true)
    var semanticClips = [alpha, image, unpinned, other]
    for (index, field) in ["title", "text", "source", "ocr", "link", "label"].enumerated() {
        var entry = clip("unrelated \(index)", kind: "文字", source: "Fixture", created: today)
        let marker = "你好学习🌟 Café cafe\u{301} Straße İSTANBUL field\(index)"
        switch field {
        case "title": entry.title = marker
        case "text": entry.text = String(repeating: "long unmatching body ", count: 10_000) + marker
        case "source": entry.source = marker
        case "ocr": entry.ocrText = marker
        case "link": entry.linkTitle = marker
        default: entry.userLabel = marker
        }
        semanticClips.append(entry)
    }
    semantic.archive.clips = semanticClips
    func originalMatches(_ clip: Clip, _ query: String) -> Bool {
        query.isEmpty || clip.title.localizedCaseInsensitiveContains(query) || clip.text.localizedCaseInsensitiveContains(query) ||
        clip.source.localizedCaseInsensitiveContains(query) || (clip.ocrText?.localizedCaseInsensitiveContains(query) ?? false) ||
        (clip.linkTitle?.localizedCaseInsensitiveContains(query) ?? false) || (clip.userLabel?.localizedCaseInsensitiveContains(query) ?? false)
    }
    for query in ["", "needle", "你好", "学习", "🌟", "CAFÉ", "cafe\u{301}", "STRASSE", "istanbul", " field", "field0", "field1", "field2", "field3", "field4", "field5", " needle ", "no-match"] {
        semantic.query = query
        await settle(semantic)
        check(semantic.filtered.map(\.id) == semanticClips.filter { originalMatches($0, query) }.map(\.id), "asynchronous search preserves original localized six-field matching: \(query)")
    }
    // Each record matches through only one field. Do not use Swift String == to
    // distinguish these fixtures: it already considers canonical forms equal.
    let unicodeStore = Store(ephemeral: true)
    let equivalentForms = [("kana", "か\u{3099}", "が"),
                           ("hangul", "\u{1100}\u{1161}", "가"),
                           ("CJK compatibility", "\u{F900}", "豈")]
    for (name, decomposed, composed) in equivalentForms {
        for (direction, forms) in [(decomposed, composed), (composed, decomposed)].enumerated() {
            let (stored, query) = forms
            let records = (0..<6).map { field -> Clip in
                var entry = clip("unrelated \(field)", kind: "文字", source: "Fixture", created: today)
                switch field {
                case 0: entry.title = stored
                case 1: entry.text = String(repeating: "long unrelated body ", count: 300) + stored
                case 2: entry.source = stored
                case 3: entry.ocrText = stored
                case 4: entry.linkTitle = stored
                default: entry.userLabel = stored
                }
                return entry
            }
            let fixtures = records + [clip("negative control", kind: "文字", source: "Fixture", created: today)]
            let expected = fixtures.filter { originalMatches($0, query) }.map(\.id)
            check(expected == records.map(\.id), "\(name) direction \(direction): original predicate matches each of six fields")
            unicodeStore.archive.clips = fixtures
            unicodeStore.query = query
            await settle(unicodeStore)
            check(unicodeStore.filtered.map(\.id) == expected, "\(name) direction \(direction): cold Unicode matching preserves all six field IDs and order")
            unicodeStore.query = "absent Unicode fixture"
            await settle(unicodeStore)
            check(unicodeStore.filtered.isEmpty, "\(name) direction \(direction): unrelated query has no result")
            unicodeStore.query = query
            await settle(unicodeStore)
            check(unicodeStore.filtered.map(\.id) == expected, "\(name) direction \(direction): warm Unicode matching restores all six field IDs and order")
        }
    }
    // Cross all four preparation workers and several 128-record batches. Check
    // complete ordered IDs, including matches in short optional fields and at
    // the end of the full body, rather than checking only a result count.
    let parallelGate = SearchTestGate()
    let parallelPipeline = SearchPipeline(beforePreparingFirstDocument: parallelGate.visit)
    let parallelStore = Store(ephemeral: true, searchPipeline: parallelPipeline)
    var parallelClips = (0..<769).map { index -> Clip in
        var entry = clip("unrelated \(index)", kind: "文字", source: "Fixture", created: today)
        let marker = index.isMultiple(of: 7) ? "か\u{3099} café \u{F900}" : "plain unrelated"
        switch index % 6 {
        case 0: entry.title = marker
        case 1: entry.text = String(repeating: "long body ", count: 400) + marker
        case 2: entry.source = marker
        case 3: entry.ocrText = marker
        case 4: entry.linkTitle = marker
        default: entry.userLabel = marker
        }
        return entry
    }
    await settle(parallelStore)
    parallelGate.arm("が")
    parallelStore.archive.clips = parallelClips
    parallelStore.query = "が"
    let preparationBlocked = await parallelGate.waitUntilBlocked()
    check(preparationBlocked, "cold native preparation reaches a controlled worker gate")
    // Cancel while one preparation worker is blocked, then edit and delete
    // records. Completed native strings from the old request must not make the
    // latest archive install stale text or the wrong document ordering.
    parallelClips[0].title = "edited away"
    parallelClips.remove(at: 128)
    parallelStore.archive.clips = parallelClips
    parallelStore.query = "豈"
    parallelGate.release()
    await settle(parallelStore)
    check(parallelStore.filtered.map(\.id) == parallelClips.filter { originalMatches($0, "豈") }.map(\.id),
          "cancelled parallel preparation reuses only valid documents after an edit and deletion")
    check(parallelPipeline.debugCacheStatistics.documentCount == parallelClips.count &&
          parallelPipeline.debugCacheStatistics.orderedDocumentCount == parallelClips.count,
          "parallel preparation publishes exactly the latest archive membership")
    for query in ["が", "CAFÉ", "not present", "豈", ""] {
        parallelStore.query = query
        await settle(parallelStore)
        check(parallelStore.filtered.map(\.id) == parallelClips.filter { originalMatches($0, query) }.map(\.id),
              "parallel prepared cache preserves full six-field Unicode matching and order: \(query)")
    }
    var edited = semanticClips[5]
    edited.text = "replacement searchable content"
    semantic.archive.clips[5] = edited
    semantic.query = "field1"
    await settle(semantic)
    check(semantic.filtered.isEmpty, "same-ID edited text invalidates prepared search strings")
    semantic.query = "replacement searchable"
    await settle(semantic)
    check(semantic.filtered.map(\.id) == [edited.id], "updated text is immediately searchable after its result commits")

    let gate = SearchTestGate()
    let racing = Store(ephemeral: true, searchPipeline: SearchPipeline(beforeScan: gate.visit))
    racing.archive.clips = [alpha, image, unpinned, other]
    await settle(racing)
    let installed = racing.searchAppliedGeneration
    let originalIDs = racing.filtered.map(\.id)
    gate.arm("blocked-query")
    racing.query = "blocked-query"
    let firstWorkerBlocked = await gate.waitUntilBlocked()
    check(firstWorkerBlocked, "controlled old search reaches its worker gate")
    check(racing.searchPending && racing.searchAppliedGeneration == installed && racing.filtered.map(\.id) == originalIDs,
          "pending search retains its prior snapshot without marking it current")
    let selectedBeforePendingMove = racing.selected
    racing.moveSelection(1)
    racing.choose(image.id)
    racing.deleteChosen()
    check(racing.selected == selectedBeforePendingMove, "pending navigation cannot choose a stale result")
    check(racing.archive.clips.map(\.id) == originalIDs, "pending selection commands cannot delete the old query's records")
    for index in 0..<100 { racing.query = "superseded-\(index)" }
    racing.query = "needle alpha"
    let expectedGeneration = racing.searchRequestGeneration
    gate.release()
    await settle(racing)
    check(racing.searchAppliedGeneration == expectedGeneration && racing.filtered.map(\.id) == [alpha.id], "only the latest query installs after an older worker is cancelled")
    check(!gate.queries.contains(where: { $0.hasPrefix("superseded-") }), "queued intermediate queries are replaced rather than scanned")

    gate.arm("needle")
    racing.query = "needle"
    let archiveWorkerBlocked = await gate.waitUntilBlocked()
    check(archiveWorkerBlocked, "archive race pauses an old snapshot")
    racing.archive.clips.removeAll { $0.id == alpha.id }
    racing.invalidatePendingStorageCallbacks()
    racing.requestSearchSelection(.preferred(image.id))
    gate.release()
    await settle(racing)
    check(racing.filtered.map(\.id) == [image.id, unpinned.id] && racing.selected == image.id,
          "archive and storage revisions reject deleted rows and resolve selection against new results")
    check(racing.visibleIndex(of: alpha.id) == nil && racing.visibleIndex(of: image.id) == 0,
          "result IDs and visible indices commit together after an archive race")

    racing.setSearchInput("needle", isComposing: true)
    let compositionGeneration = racing.searchRequestGeneration
    check(racing.searchInputIsComposing && racing.searchPending, "IME marked text invalidates old results immediately")
    racing.setSearchInput("needle", isComposing: false)
    await settle(racing)
    check(!racing.searchInputIsComposing && racing.searchAppliedGeneration > compositionGeneration && racing.filtered.count == 2,
          "IME committing unchanged draft text still schedules the committed search")
    racing.setSearchInput("uncommitted", isComposing: true)
    racing.cancelSearchInput()
    await settle(racing)
    check(racing.query.isEmpty && !racing.searchPending && !racing.searchInputIsComposing && racing.filtered.count == 3,
          "cancelling composition restores empty-query results without an old query returning")
    racing.selected = image.id
    racing.selection = [image.id, unpinned.id]
    racing.selectionAnchor = image.id
    racing.query = "no-result"
    await settle(racing)
    check(racing.filtered.isEmpty && racing.selected == nil && racing.selection.isEmpty && racing.selectionAnchor == nil,
          "empty async result clears all selection state including its anchor")

    let cachePipeline = SearchPipeline()
    let cacheStore = Store(ephemeral: true, searchPipeline: cachePipeline)
    cacheStore.archive.clips = semanticClips
    cacheStore.query = "field"
    await settle(cacheStore)
    let populatedCache = cachePipeline.debugCacheStatistics
    check(populatedCache.documentCount == semanticClips.count && populatedCache.nativeUTF16CodeUnitCount > 0,
          "nonempty search prepares the full current archive cache")
    cacheStore.query = ""
    await settle(cacheStore)
    cacheStore.archive.clips.removeLast(3)
    await settle(cacheStore)
    let prunedCache = cachePipeline.debugCacheStatistics
    check(prunedCache.documentCount == semanticClips.count - 3 && prunedCache.orderedDocumentCount == 0,
          "empty-query deletion evicts old cached documents and ordered snapshots")
    let bytesBeforeEdit = prunedCache.nativeUTF16CodeUnitCount
    cacheStore.archive.clips[5].text = "replacement while query is empty"
    await settle(cacheStore)
    let editedCache = cachePipeline.debugCacheStatistics
    check(editedCache.documentCount == semanticClips.count - 4 && editedCache.nativeUTF16CodeUnitCount < bytesBeforeEdit,
          "same-ID edit under empty query evicts obsolete full-text cache")
    cacheStore.query = "replacement while query is empty"
    await settle(cacheStore)
    check(cacheStore.filtered.map(\.id) == [semanticClips[5].id], "search after empty-query edit rebuilds the new content")
    cacheStore.query = ""
    cacheStore.archive.clips = []
    await settle(cacheStore)
    let emptiedCache = cachePipeline.debugCacheStatistics
    check(emptiedCache.documentCount == 0 && emptiedCache.orderedDocumentCount == 0 && emptiedCache.nativeUTF16CodeUnitCount == 0,
          "empty archive releases every cached native search string")

    let cardGate = SearchCardTestGate()
    let cardCache = CardPresentationCache(beforePrepare: cardGate.visit)
    let heldCard = Task { await cardCache.value(for: alpha, directory: 0) }
    let cardBlocked = await cardGate.waitUntilBlocked()
    check(cardBlocked, "card presentation worker reaches deterministic preparation gate")
    let staleCards = (0..<100).map { index in
        let item = clip("stale card \(index)", kind: "文字", source: "Fixture", created: today)
        return Task { await cardCache.value(for: item, directory: 0) }
    }
    let queueDeadline = ProcessInfo.processInfo.systemUptime + 5
    while cardCache.statistics.queuedCount < 64 && ProcessInfo.processInfo.systemUptime < queueDeadline {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    check(cardCache.statistics.queuedCount == 64 && cardCache.statistics.queuedBytes <= 8 * 1024 * 1024,
          "card preparation queue remains bounded during rapid navigation")
    staleCards.forEach { $0.cancel() }
    for task in staleCards { _ = await task.value }
    check(cardCache.statistics.queuedCount == 0 && cardCache.statistics.queuedBytes == 0,
          "cancelling offscreen cards immediately releases queued payloads")
    heldCard.cancel()
    let cancelledCard = await heldCard.value
    check(cancelledCard == nil, "cancellation resumes a running card consumer without waiting for its worker")
    let latestCard = Task { await cardCache.value(for: other, directory: 0) }
    await Task.yield()
    cardGate.release()
    let currentCard = await latestCard.value
    check(currentCard?.summary == other.text && cardCache.statistics.preparationCount == 1,
          "cancelled card jobs skip parsing and only the latest requested card prepares")

    let duplicateGate = SearchCardTestGate()
    let duplicateCache = CardPresentationCache(beforePrepare: duplicateGate.visit)
    let firstCard = Task { await duplicateCache.value(for: alpha, directory: 0) }
    let duplicateBlocked = await duplicateGate.waitUntilBlocked()
    check(duplicateBlocked, "shared card request reaches worker gate")
    let secondCard = Task { await duplicateCache.value(for: alpha, directory: 0) }
    await Task.yield()
    duplicateGate.release()
    let firstValue = await firstCard.value
    let secondValue = await secondCard.value
    check(firstValue?.summary == alpha.text && secondValue?.summary == alpha.text && duplicateCache.statistics.preparationCount == 1,
          "identical card requests share one preparation and both receive the immutable result")

    let formatCache = CardPresentationCache()
    var formatClip = clip("same visible text", kind: "文字", source: "Fixture", created: today)
    formatClip.cachedDigest = nil
    let plainPresentation = await formatCache.value(for: formatClip, directory: 0)
    formatClip.parts[0].append(ClipPart(type: "public.rtf", data: Data("{\\rtf1\\b same visible text}".utf8)))
    let rtfPresentation = await formatCache.value(for: formatClip, directory: 0)
    formatClip.parts[0].removeLast()
    formatClip.parts[0].append(ClipPart(type: "public.html", data: Data("<b>same visible text</b>".utf8)))
    let htmlPresentation = await formatCache.value(for: formatClip, directory: 0)
    check(plainPresentation?.richText == false && rtfPresentation?.richText == true && htmlPresentation?.richText == false &&
          formatCache.statistics.preparationCount == 3,
          "nil-digest same-ID plain to RTF to HTML format changes invalidate card presentation cache")

    checks += runShelfRenderingPolicyTests()
    checks += await runShelfSearchEditorTests()
    checks += await runShelfPreviewHostTests()
    print("\(checks) filter and navigation tests passed")
}

private final class SearchCardTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var first = true
    private var blocked = false
    func visit() {
        lock.lock()
        let shouldWait = first
        first = false
        if shouldWait { blocked = true }
        lock.unlock()
        if shouldWait { _ = semaphore.wait(timeout: .now() + 10) }
    }
    func release() { semaphore.signal() }
    private var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    @MainActor func waitUntilBlocked() async -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + 5
        while !isBlocked {
            if ProcessInfo.processInfo.systemUptime >= end { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }
}

/// A worker-only gate, so tests exercise real admission/cancellation and main-actor
/// installation without sleeping on or replacing the production search path.
private final class SearchTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var target: String?
    private var semaphore = DispatchSemaphore(value: 0)
    private var blocked = false
    private var visited: [String] = []
    var queries: [String] { lock.lock(); defer { lock.unlock() }; return visited }
    func arm(_ query: String) {
        lock.lock(); defer { lock.unlock() }
        target = query; blocked = false; semaphore = DispatchSemaphore(value: 0)
    }
    func visit(_ request: SearchRequest) {
        lock.lock()
        visited.append(request.criteria.query)
        let shouldBlock = request.criteria.query == target
        let wait = semaphore
        if shouldBlock { target = nil; blocked = true }
        lock.unlock()
        if shouldBlock { _ = wait.wait(timeout: .now() + 10) }
    }
    func release() { lock.lock(); let wait = semaphore; lock.unlock(); wait.signal() }
    private var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    @MainActor func waitUntilBlocked() async -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + 5
        while !isBlocked {
            if ProcessInfo.processInfo.systemUptime >= end { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }
}
