import AppKit

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
    store.setTimeScope(.today)
    check(store.todayOnly && !store.dateRangeEnabled && store.timeScope == .today && store.filterPasses == noOpPasses + 1, "choosing today refreshes once")
    store.setTimeScope(.custom)
    check(!store.todayOnly && store.dateRangeEnabled && store.timeScope == .custom && store.filterPasses == noOpPasses + 2, "switching from today to the custom range refreshes once, not once per flag")
    store.setTimeScope(.custom)
    check(store.filterPasses == noOpPasses + 2, "choosing the time scope that is already active is a no-op")
    store.setTimeScope(.any)
    check(!store.todayOnly && !store.dateRangeEnabled && store.timeScope == .any && store.filterPasses == noOpPasses + 3, "choosing no time filter refreshes once")

    store.selection = [alpha.id, other.id]
    store.selected = alpha.id
    store.query = "missing value"
    check(store.filtered.isEmpty && store.selected == nil && store.selection.isEmpty, "no-result filter clears stale selection")
    store.resetFilters()
    check(store.filtered.count == 4 && store.selected == alpha.id, "clearing filters restores results and a valid selection")
    store.query = "missing value"; store.kind = "文字"; store.todayOnly = true
    let passesBeforeClear = store.filterPasses
    store.clearFilters()
    check(store.query == "missing value" && store.kind == "全部" && !store.todayOnly && !store.filtersActive && store.filterPasses == passesBeforeClear + 1, "the filter card's clear keeps the search text and refreshes once")
    store.resetFilters()
    store.selected = alpha.id
    store.moveSelection(-1)
    check(store.selected == alpha.id, "navigation clamps at the first result")
    check(!store.keyboardNavigated, "an arrow key that cannot move the selection does not ask for the magnification")
    store.moveSelection(1)
    check(store.selected == image.id && store.selection.isEmpty && store.selectionAnchor == image.id, "navigation advances and resets multi-selection")
    check(store.keyboardNavigated, "an arrow key that moves the selection asks for the magnification")
    store.keyboardNavigated = false
    store.selected = other.id
    check(!store.keyboardNavigated, "selecting without the keyboard never asks for the magnification")
    store.moveSelection(1)
    check(store.selected == other.id, "navigation clamps at the last result")
    check(!store.keyboardNavigated, "an arrow key at the last result does not ask for the magnification")
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

    let rest = CardMagnification.restScale
    let bell = stride(from: 0.0, through: CardMagnification.reach + 2, by: 0.25).map { CardMagnification.scale(distance: $0, intensity: 1) }
    check(bell[0] == 1 && zip(bell, bell.dropFirst()).allSatisfy { $0 >= $1 } && bell.last == rest && CardMagnification.scale(distance: -1.5, intensity: 1) == CardMagnification.scale(distance: 1.5, intensity: 1), "magnification falls off smoothly and symmetrically from the focus to the resting scale")
    check(stride(from: 0.0, through: 8.0, by: 0.5).allSatisfy { CardMagnification.scale(distance: $0, intensity: 0) == 1 }, "without the effect every card is drawn at full size")
    check(CardMagnification.farScale(intensity: 1) == rest && CardMagnification.farScale(intensity: 0) == 1 && CardMagnification.farScale(intensity: 0.5) > rest && CardMagnification.farScale(intensity: 0.5) < 1 && CardMagnification.farScale(intensity: 9) == rest, "the far scale runs from 1 (no effect) to the resting scale (full effect)")
    let viewport: CGFloat = 1280
    let lead = CardMagnification.stripLeading, spacing = CardMagnification.spacing
    func layout(_ focus: Double, _ count: Int, _ width: CGFloat, _ intensity: Double, leading: CGFloat = 0, pan: CGFloat = 0, viewport: CGFloat = viewport) -> CardMagnification.Frame {
        CardMagnification.frame(focus: focus, count: count, cardWidth: width, viewport: viewport, intensity: intensity, extraLeading: leading, pan: pan)
    }
    check(CardMagnification.cardWidth(compact: false) == 240 && CardMagnification.cardWidth(compact: true) == 180, "one card width per mode")
    for width in [CGFloat(240), 180] {
        for count in [1, 4, 9, 20, 200] {
            for intensity in [0.0, 0.4, 1.0] {
                for leading in [CGFloat(0), width + spacing] {
                    var worstGap: CGFloat = 0
                    var focusCentreOK = true, startOK = true, endOK = true
                    for step in stride(from: 0, through: max(0, (count - 1) * 4), by: count > 20 ? 7 : 1) {
                        let focus = Double(step) / 4
                        let f = layout(focus, count, width, intensity, leading: leading)
                        let near = max(0, Int(focus) - 8)...max(0, min(count - 2, Int(focus) + 8))
                        for i in (count > 20 ? Array(near) + [0, count - 2] : Array(0..<max(0, count - 1))) where i + 1 < count {
                            worstGap = max(worstGap, abs(f.left(i + 1) - f.right(i) - spacing))
                        }
                        // Start: card 0 never leaves a gap after the padding and the placeholder, and never covers the placeholder.
                        if f.left(0) > lead + leading + 0.01 { startOK = false }
                        if focus == 0 && abs(f.left(0) - (lead + leading)) > 0.01 { startOK = false }
                        // End: a strip longer than the viewport never leaves a gap after the last card.
                        if f.right(count - 1) - f.left(0) > viewport - 2 * lead - leading && f.right(count - 1) < viewport - lead - 0.01 { endOK = false }
                        if count == 200 && focus >= 8 && focus <= 190 && focus == focus.rounded() && abs(f.centre(Int(focus)) - viewport / 2) > 0.01 { focusCentreOK = false }
                    }
                    let label = "count \(count), width \(width), intensity \(intensity), leading \(leading)"
                    check(worstGap < 0.01, "the gap between neighbours stays at the spacing (\(label), worst error \(worstGap))")
                    check(startOK, "the first card starts at the padding, after the translation placeholder, never over it (\(label))")
                    check(endOK, "no gap after the last card (\(label))")
                    check(focusCentreOK, "away from both ends the focus card is exactly in the middle (\(label))")
                }
            }
            // At rest (no effect) the cards are exactly as before: full size, 12 pt apart, first card at the left padding.
            let idle = layout(0, count, width, 0)
            check((0..<count).allSatisfy { idle.scale($0) == 1 }, "at rest every card is drawn at full size (count \(count), width \(width))")
            check(abs(idle.left(0) - lead) < 0.01 && (count < 2 || abs(idle.left(1) - idle.right(0) - spacing) < 0.01), "at rest the first card starts at the left padding with the original spacing (count \(count), width \(width))")
            // Continuity: neither a small focus step nor a small intensity step may make a card jump.
            guard count > 1 else { continue }
            let mid = min(count - 1, 8)
            var maxScale: CGFloat = 0, maxMove: CGFloat = 0
            func compare(_ a: CardMagnification.Frame, _ b: CardMagnification.Frame) {
                for i in max(0, mid - 4)...min(count - 1, mid + 4) { maxScale = max(maxScale, abs(a.scale(i) - b.scale(i))); maxMove = max(maxMove, abs(a.centre(i) - b.centre(i))) }
            }
            for intensity in [0.0, 1.0] {
                var previous: CardMagnification.Frame?
                for step in 0...200 {
                    let f = layout(Double(mid) - 1 + Double(step) / 100, count, width, intensity)
                    if let previous { compare(previous, f) }
                    previous = f
                }
            }
            var previous: CardMagnification.Frame?
            for step in 0...100 {
                let f = layout(Double(mid), count, width, Double(step) / 100)
                if let previous { compare(previous, f) }
                previous = f
            }
            check(maxScale < 0.02 && maxMove < 5, "moving the focus by 0.01 cards or the intensity by 0.01 never makes a visible card jump (count \(count), width \(width), scale step \(maxScale), move step \(maxMove))")
        }
        // Panning: the strip moves by exactly the pan, stops at both ends, and a short strip cannot pan.
        let centre50 = layout(50, 200, width, 0)
        check(abs(layout(50, 200, width, 0, pan: -700).centre(50) - (centre50.centre(50) - 700)) < 0.001, "a pan moves every card by exactly that many points (width \(width))")
        check(layout(0, 200, width, 0).panRange.upperBound == 0 && abs(layout(0, 200, width, 0, pan: 300).left(0) - lead) < 0.001, "at the start the strip cannot be pulled away from the left padding (width \(width))")
        let farRight = layout(50, 200, width, 0, pan: -1e9)
        check(abs(farRight.right(199) - (viewport - lead)) < 0.001 && abs(farRight.pan - farRight.panRange.lowerBound) < 0.001, "panning to the end stops with the last card at the right padding (width \(width))")
        check(layout(1, 3, width, 0, pan: -400).panRange == 0...0 && abs(layout(1, 3, width, 0, pan: -400).left(0) - lead) < 0.001, "a strip shorter than the shelf cannot pan (width \(width))")
        // The pan is one number with the drawn position: turning it back into focus shows the same strip.
        for pan in [CGFloat(-2000), -333, 0, 600] {
            let panned = layout(50, 200, width, 0, pan: pan)
            let focus = CardMagnification.focus(showing: panned.firstLeft, count: 200, cardWidth: width, viewport: viewport, intensity: 0)
            check(abs(layout(focus, 200, width, 0).firstLeft - panned.firstLeft) < 0.5, "a pan of \(pan) maps back to a focus that shows the same strip (width \(width))")
        }
        // Only the cards on screen are built, however long the history.
        for (focus, pan) in [(0.0, CGFloat(0)), (3_000, 0), (3_000, -5_000), (7_499, 0), (120, 2_000)] {
            for intensity in [0.0, 1.0] {
                let f = layout(focus, 7_500, width, intensity, pan: pan)
                let range = f.visible(margin: 0)
                let onScreen = (0..<7_500).filter { f.right($0) >= 0 && f.left($0) <= viewport }
                check(range.count <= 20 && onScreen.allSatisfy { range.contains($0) }, "the strip builds only the \(range.count) cards on screen and every one of them (focus \(focus), pan \(pan), intensity \(intensity), width \(width))")
            }
        }
    }
    // The viewport width and the compact card width are inputs of every frame, so a resized or compact shelf is redrawn
    // around the same selection with nothing to re-sync.
    check(abs(layout(30, 200, 180, 0, viewport: 900).centre(30) - 450) < 0.001 && abs(layout(30, 200, 240, 0, viewport: 1600).centre(30) - 800) < 0.001, "a resized or compact shelf keeps the selection in the middle")
    do {
        var envelope = MagnifyEnvelope()
        check(envelope.value == 0 && envelope.settled, "the magnification starts off")
        envelope.keyPressed()
        for _ in 0..<12 { envelope.advance(by: 1.0 / 60.0) }
        check(envelope.value > 0.85, "the magnification is nearly full within 0.2 s of an arrow key (\(envelope.value))")
        for _ in 0..<30 { envelope.advance(by: 1.0 / 60.0) }
        check(envelope.value > 0.99 && !envelope.settled, "the magnification stays on while the keys were used a moment ago")
        for _ in 0..<(60 * 2) { envelope.advance(by: 1.0 / 60.0) }
        check(envelope.value == 0 && envelope.settled, "the magnification fades back to nothing after the hold time")
        envelope.keyPressed(); envelope.advance(by: 1.0 / 60.0)
        let early = envelope.value
        envelope.keyPressed()
        for _ in 0..<(60 * 1) { envelope.advance(by: 1.0 / 60.0); envelope.keyPressed() }
        check(early > 0 && envelope.value > 0.99, "holding an arrow key keeps the magnification on")
        var slow = MagnifyEnvelope()
        slow.keyPressed()
        var steps = 0
        for _ in 0..<(60 * 4) { slow.advance(by: 1.0 / 60.0); steps += 1; if slow.settled && steps > 60 { break } }
        check(slow.settled && Double(steps) / 60 < 3.0, "the magnification is back to nothing within three seconds of a single key press (\(Double(steps) / 60) s)")
    }
    do {
        var spring = FocusSpring(value: 0, target: 1)
        var previous = 0.0, monotonic = true, overshoot = false, frames = 0
        while !spring.settled && frames < 600 {
            spring.advance(by: 1.0 / 60.0); frames += 1
            if spring.value < previous - 1e-9 { monotonic = false }
            if spring.value > 1 + 1e-9 { overshoot = true }
            previous = spring.value
        }
        check(spring.value == 1 && monotonic && !overshoot, "the focus spring reaches its target without bouncing")
        var closeIn = 0
        var probe = FocusSpring(value: 0, target: 1)
        while probe.value < 0.99 && closeIn < 600 { probe.advance(by: 1.0 / 60.0); closeIn += 1 }
        check(closeIn >= 5 && closeIn <= 20 && frames <= 40, "the focus spring gets within 1% in \(closeIn) frames and settles in \(frames)")
        var fine = FocusSpring(value: 0, target: 1), coarse = FocusSpring(value: 0, target: 1)
        for _ in 0..<30 { fine.advance(by: 1.0 / 240.0) }
        for _ in 0..<7 { coarse.advance(by: 1.0 / 56.0) }
        check(abs(fine.value - coarse.value) < 0.02, "the focus spring does not depend on the frame rate")
        var retarget = FocusSpring(value: 0, target: 1)
        for _ in 0..<5 { retarget.advance(by: 1.0 / 60.0) }
        let before = retarget.value, speed = retarget.velocity
        retarget.target = 1.5
        retarget.advance(by: 1.0 / 240.0)
        check(speed > 0 && abs(retarget.value - before) < speed / 240 * 2 && retarget.velocity > 0, "retargeting keeps the position continuous and the velocity going (no restart)")
        let driver = FocusDriver()
        let size = CGSize(width: 1280, height: 260)
        driver.snap(to: 7)
        let shared = driver.frame(count: 40, cardWidth: 240, size: size, extraLeading: 0)
        let alone = CardMagnification.frame(focus: 7, count: 40, cardWidth: 240, viewport: 1280, intensity: 0)
        check((0..<40).allSatisfy { shared.centre($0) == alone.centre($0) && shared.scale($0) == alone.scale($0) }, "the driver's frame is the layout computed for its focus")
        driver.snap(to: 30)
        let unpanned = driver.frame(count: 200, cardWidth: 240, size: size, extraLeading: 0)
        driver.scroll(by: -900)
        let panned = driver.frame(count: 200, cardWidth: 240, size: size, extraLeading: 0)
        check(driver.pan == -900 && abs(panned.centre(30) - (unpanned.centre(30) - 900)) < 0.001, "scrolling pans the drawn strip by the same amount")
        driver.scroll(by: 1e9)
        check(driver.pan == driver.frame(count: 200, cardWidth: 240, size: size, extraLeading: 0).panRange.upperBound, "scrolling stops at the start of the strip")
        driver.scroll(by: -900 - driver.pan)
        driver.follow(index: 31)
        check(driver.target == 31 && driver.value == 31 && driver.pan == -900, "a clip inserted before the selection shifts the focus and keeps the pan")
        driver.snap(to: 30); driver.scroll(by: -900)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let shown = driver.frame(count: 200, cardWidth: 240, size: size, extraLeading: 0).firstLeft
            driver.move(to: 35)
            let start = driver.frame(count: 200, cardWidth: 240, size: size, extraLeading: 0).firstLeft
            check(driver.pan == 0 && driver.target == 35 && abs(start - shown) < 0.5, "a new selection after scrolling glides from what is on screen instead of jumping back (\(start - shown) pt)")
        }
        driver.snap(to: 30); driver.scroll(by: -900); driver.snap(to: 30)
        check(driver.pan == 0, "reopening the shelf drops the pan")
        check(driver.restingRect(index: 30) == nil, "without a drawn strip there is no preview anchor")
        // Built cards stay built while the strip moves back and forth nearby, up to the old render batch.
        let keeper = FocusDriver()
        check(keeper.keptRange(around: 10..<16, count: 200) == 4..<22, "cards about a screen either side of the view are built")
        check(keeper.keptRange(around: 30..<36, count: 200) == 4..<42, "moving on keeps the cards already built nearby")
        check(keeper.keptRange(around: 10..<16, count: 200) == 4..<42, "moving back rebuilds nothing")
        check(keeper.keptRange(around: 150..<156, count: 200) == 144..<162, "a far jump drops cards beyond the limit instead of keeping more than \(FocusDriver.keptCards)")
        check(keeper.keptRange(around: 2..<8, count: 5) == 0..<5, "the kept cards never run past the end of a shorter list")
        check(FocusDriver.keptCards == 64, "at most 64 cards are kept built")
        // A click selects at once and a double-click pastes; reading the click count of a non-mouse event must not raise.
        func mouse(_ count: Int) -> NSEvent? { NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1) }
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)
        check(isDoubleClick(mouse(2)) && !isDoubleClick(mouse(1)) && !isDoubleClick(key) && !isDoubleClick(nil), "only the second click of a mouse double-click counts as a double-click")
        var held = FocusSpring(value: 0, target: 0)
        var lag = 0.0
        for step in 1...100 { held.target = Double(step); held.advance(by: 0.033); lag = max(lag, held.target - held.value) }
        var capped = FocusSpring(value: 0, target: 0)
        capped.target = 5; capped.limitLag()
        check(abs(capped.value - (5 - FocusSpring.maxLag)) < 1e-9, "a target far ahead of the focus is pulled back to the lag limit")
        check(lag <= FocusSpring.maxLag + 1e-9, "at a 30 ms key repeat the focus stays within \(lag) cards of the selection")
    }

    print("\(checks) filter and navigation tests passed")
}
