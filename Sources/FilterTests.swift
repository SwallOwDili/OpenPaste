import Foundation

func runFilterTests() {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { print("FAIL: \(label)"); exit(1) }
        checks += 1
        print("PASS: \(label)")
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
    check(store.filterPasses == preservedPasses + 1, "batched reset performs one filter pass")
    check(store.board == board && store.dateRangeEnabled && store.startDate == yesterday && store.endDate == today, "optional reset preserves board and explicit date range")
    check(store.query.isEmpty && store.kind == "全部" && store.sourceFilter == "全部来源" && !store.todayOnly, "reset clears all other filters")

    let clearPasses = store.filterPasses
    store.resetFilters()
    check(store.filterPasses == clearPasses + 1 && store.board == nil && !store.dateRangeEnabled, "default reset clears board and date range in one pass")
    let noOpPasses = store.filterPasses
    store.resetFilters()
    check(store.filterPasses == noOpPasses, "resetting default filters is a no-op")

    store.selection = [alpha.id, other.id]
    store.selected = alpha.id
    store.query = "missing value"
    check(store.filtered.isEmpty && store.selected == nil && store.selection.isEmpty, "no-result filter clears stale selection")
    store.resetFilters()
    check(store.filtered.count == 4 && store.selected == alpha.id, "clearing filters restores results and a valid selection")
    store.moveSelection(-1)
    check(store.selected == alpha.id, "navigation clamps at the first result")
    store.moveSelection(1)
    check(store.selected == image.id && store.selection.isEmpty && store.selectionAnchor == image.id, "navigation advances and resets multi-selection")
    store.selected = other.id
    store.moveSelection(1)
    check(store.selected == other.id, "navigation clamps at the last result")
    store.reverseHistory = true
    check(store.filtered.first?.id == other.id && store.selected == other.id, "reverse order rebuilds the visible index and selects its first result")
    store.moveSelection(1)
    check(store.selected == unpinned.id, "navigation follows reversed visible order")
    store.reverseHistory = false

    let updatedSourcePasses = store.sourcePasses
    store.archive.clips.append(clip("new source", kind: "文字", source: "Browser", created: today))
    check(store.sourcePasses == updatedSourcePasses + 1 && store.sources == ["Browser", "Camera", "Editor"], "archive change rebuilds source names once")

    let performance = Store(ephemeral: true)
    let clips = (0..<5_000).map { index in clip("Item \(index)", kind: "文字", source: "Fixture", created: today) }
    performance.archive.clips = clips
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
    let sourcePassesBeforeInstall = install.sourcePasses
    let filterPassesBeforeInstall = install.filterPasses
    let mutationBeforeInstall = install.directoryMutation
    install.installLoadedArchive(Archive(clips: loadedClips, boards: []))
    check(install.sourcePasses == sourcePassesBeforeInstall + 1 && install.filterPasses == filterPassesBeforeInstall + 1, "loaded archive publishes one source and filter refresh")
    check(!install.archive.clips.contains(where: { $0.id == expired.id }) && install.archive.clips.contains(where: { $0.id == favorite.id }), "loaded archive retention removes expired history and preserves favorites")
    check(install.archive.clips.count == loadedClips.count - 1 && install.limit == loadedClips.filter { $0.boards.isEmpty }.count, "loaded archive expands the history limit before pruning saved records")
    check(install.storageLimitMB >= 2 && install.archive.clips.contains(where: { $0.id == large.id }), "loaded archive expands storage capacity before pruning saved records")
    check(install.directoryMutation == mutationBeforeInstall, "loaded archive capacity updates do not schedule a save")

    let ingestStore = Store(ephemeral: true)
    ingestStore.limit = 0
    ingestStore.archive.clips = (0..<500).map { clip("ingest \($0)", kind: "文字", source: "Fixture", created: today.addingTimeInterval(Double(-$0))) }
    let ingestPasses = ingestStore.filterPasses, ingestSources = ingestStore.sourcePasses
    ingestStore.ingest(clip("brand new", kind: "文字", source: "Fixture", created: today.addingTimeInterval(10)))
    check(ingestStore.filterPasses == ingestPasses + 1 && ingestStore.sourcePasses == ingestSources + 1 && ingestStore.archive.clips.count == 501, "ingest without pruning publishes the history once")
    ingestStore.limit = 100
    let cappedPasses = ingestStore.filterPasses
    ingestStore.ingest(clip("another new", kind: "文字", source: "Fixture", created: today.addingTimeInterval(20)))
    check(ingestStore.filterPasses == cappedPasses + 1 && ingestStore.archive.clips.count == 100, "ingest that prunes still publishes the history once")
    let untouchedPasses = ingestStore.filterPasses
    ingestStore.prune()
    check(ingestStore.filterPasses == untouchedPasses, "prune without removals does not republish the history")

    let ocrStore = Store(ephemeral: true)
    let ocrClips = (0..<3).map { clip("image \($0)", kind: "图片", source: "Fixture", created: today.addingTimeInterval(Double(-$0))) }
    ocrStore.archive.clips = ocrClips
    let ocrPasses = ocrStore.filterPasses
    var stale = ocrClips[2]; stale.parts = [[ClipPart(type: "public.data", data: Data([9]))]]; stale.cachedDigest = nil
    let applied = ocrStore.applyRecognizedTexts([(ocrClips[0], "zero"), (ocrClips[1], "one"), (stale, "stale")], storageGeneration: ocrStore.storageCallbackGeneration)
    check(applied == 2 && ocrStore.filterPasses == ocrPasses + 1, "OCR results from one batch publish the history once and skip changed clips")
    check(ocrStore.archive.clips[0].ocrText == "zero" && ocrStore.archive.clips[1].ocrText == "one" && ocrStore.archive.clips[2].ocrText == nil, "OCR batch writes text only to matching clips")

    check(ShelfRenderWindow.initialCount(total: 5_000) == 64 && ShelfRenderWindow.initialCount(total: 12) == 12, "shelf render window starts with at most 64 records")
    check(ShelfRenderWindow.nextCount(current: 64, total: 5_000) == 128 && ShelfRenderWindow.nextCount(current: 128, total: 150) == 150, "shelf render window grows by 64 and clamps to the result count")
    check(ShelfRenderWindow.countIncluding(index: 63, total: 5_000) == 64 && ShelfRenderWindow.countIncluding(index: 64, total: 5_000) == 128 && ShelfRenderWindow.countIncluding(index: 191, total: 5_000) == 192, "shelf render window includes keyboard selections at batch boundaries")
    check(ShelfRenderWindow.resetCount(total: 5_000, selectedIndex: nil) == 64 && ShelfRenderWindow.resetCount(total: 5_000, selectedIndex: 130) == 192, "shelf filter reset preserves an out-of-window selection")

    print("\(checks) filter and navigation tests passed")
}
