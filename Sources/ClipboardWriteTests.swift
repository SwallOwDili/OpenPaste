import AppKit

private final class MissingPasteboardDataProvider: NSObject, NSPasteboardItemDataProvider {
    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
}

private final class ReplacingPasteboardDataProvider: NSObject, NSPasteboardItemDataProvider {
    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        pasteboard?.clearContents()
        pasteboard?.setString("new owner during snapshot", forType: .string)
    }
}

private final class SlowPasteboardDataProvider: NSObject, NSPasteboardItemDataProvider {
    let delay: TimeInterval
    private let lock = NSLock()
    private var requestCount = 0

    init(delay: TimeInterval) { self.delay = delay }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        Thread.sleep(forTimeInterval: delay)
        lock.lock(); requestCount += 1; lock.unlock()
        item.setData(Data("slow old data".utf8), forType: type)
    }

    var requests: Int {
        lock.lock(); defer { lock.unlock() }
        return requestCount
    }
}

func runClipboardWriteTests() {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { print("FAIL: \(label)"); exit(1) }
        checks += 1
        print("PASS: \(label)")
    }
    func item(_ values: [(String, Data)]) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for (type, data) in values { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
        return item
    }

    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let textType = NSPasteboard.PasteboardType.string
    let customType = NSPasteboard.PasteboardType("example.clipboard.fixture")
    let secondType = NSPasteboard.PasteboardType("example.clipboard.second")

    pasteboard.clearContents()
    pasteboard.setString("before", forType: textType)
    func replacement() -> NSPasteboardItem { item([(textType.rawValue, Data("after".utf8))]) }
    check(ClipboardWrite.attempt([replacement()], to: pasteboard) == .written, "valid payload writes successfully")
    check(pasteboard.string(forType: textType) == "after", "successful write replaces clipboard content")

    let countBeforeEmpty = pasteboard.changeCount
    check(ClipboardWrite.attempt([], to: pasteboard) == .rejected && ClipboardWrite.attempt([NSPasteboardItem()], to: pasteboard) == .rejected, "empty payload and typeless item are rejected")
    check(pasteboard.changeCount == countBeforeEmpty && pasteboard.string(forType: textType) == "after", "invalid payload leaves clipboard unchanged")

    let unreadableType = NSPasteboard.PasteboardType("com.example.clipboard.unreadable")
    let missingProvider = MissingPasteboardDataProvider()
    let partlyReadable = item([(textType.rawValue, Data("readable old text".utf8))])
    check(partlyReadable.setDataProvider(missingProvider, forTypes: [unreadableType]), "fixture declares a lazy unreadable representation")
    pasteboard.clearContents()
    check(pasteboard.writeObjects([partlyReadable]), "fixture writes readable and promised representations")
    let unreadableStartCount = pasteboard.changeCount
    let unreadableStartTypes = Set(pasteboard.pasteboardItems?.first?.types ?? [])
    check(unreadableStartTypes == Set([textType, unreadableType]), "fixture contains both readable and unreadable old representations")
    check(ClipboardWrite.snapshot(pasteboard) == nil, "complete snapshot rejects an unreadable representation")
    let ordinaryWrite = ClipboardWrite.attempt([replacement()], to: pasteboard)
    check(ordinaryWrite == .written && pasteboard.string(forType: textType) == "after", "ordinary user write is not blocked by an unreadable old representation")
    check(pasteboard.changeCount == unreadableStartCount + 1 && Set(pasteboard.pasteboardItems?.first?.types ?? []) == Set([textType]), "ordinary write takes ownership once and installs only the requested representation")

    let slowProvider = SlowPasteboardDataProvider(delay: 0.300)
    let slowItem = NSPasteboardItem()
    check(slowItem.setDataProvider(slowProvider, forTypes: [unreadableType]), "performance fixture declares a 300 ms delayed old representation")
    pasteboard.clearContents()
    check(pasteboard.writeObjects([slowItem]), "performance fixture is writable")
    let slowStart = ProcessInfo.processInfo.systemUptime
    check(ClipboardWrite.attempt([replacement()], to: pasteboard) == .written, "ordinary write succeeds over delayed old content")
    let ordinaryElapsed = ProcessInfo.processInfo.systemUptime - slowStart
    print(String(format: "INFO: ordinary write %.1f ms; delayed-provider baseline %.1f ms", ordinaryElapsed * 1_000, slowProvider.delay * 1_000))
    check(slowProvider.requests == 0, "ordinary write does not request delayed old clipboard data")
    check(ordinaryElapsed < slowProvider.delay, "ordinary write completes before the old provider delay")

    func textClip(_ value: String) -> Clip {
        Clip(
            source: "Fixture",
            sourceID: "example.clipboard.call-chain",
            kind: "文字",
            title: value,
            text: value,
            parts: [[ClipPart(type: textType.rawValue, data: Data(value.utf8))]]
        )
    }
    func installDelayedOldContent(_ provider: SlowPasteboardDataProvider, _ label: String) {
        let delayed = NSPasteboardItem()
        check(delayed.setDataProvider(provider, forTypes: [unreadableType]), "\(label) declares delayed old content")
        pasteboard.clearContents()
        check(pasteboard.writeObjects([delayed]), "\(label) installs delayed old content")
    }

    let callChainStore = Store(ephemeral: true)
    let single = textClip("single call-chain write")
    callChainStore.archive.clips = [single]
    let singleProvider = SlowPasteboardDataProvider(delay: 0.300)
    installDelayedOldContent(singleProvider, "single restore fixture")
    check(callChainStore.restore(single, plain: false, pasteboard: pasteboard) && pasteboard.string(forType: textType) == single.text, "Store.restore writes the selected item over delayed old content")
    check(singleProvider.requests == 0, "Store.restore does not request delayed old clipboard data")

    let first = textClip("first multi item")
    let second = textClip("second multi item")
    callChainStore.archive.clips = [first, second]
    let multiProvider = SlowPasteboardDataProvider(delay: 0.300)
    installDelayedOldContent(multiProvider, "multi restore fixture")
    check(callChainStore.restoreMany([first, second], plain: false, pasteboard: pasteboard) && pasteboard.string(forType: textType) == "\(first.text)\n\(second.text)", "Store.restoreMany writes all selected text over delayed old content")
    check(multiProvider.requests == 0, "Store.restoreMany does not request delayed old clipboard data")

    let queued = textClip("queued call-chain write")
    callChainStore.archive.clips = [queued]
    callChainStore.pasteQueue = [queued.id]
    let queueProvider = SlowPasteboardDataProvider(delay: 0.300)
    installDelayedOldContent(queueProvider, "queue restore fixture")
    check(callChainStore.prepareNextQueuedPaste(pasteboard: pasteboard) == .ready && pasteboard.string(forType: textType) == queued.text, "prepareNextQueuedPaste writes the queued item over delayed old content")
    check(callChainStore.pasteQueue.isEmpty, "successful queued call-chain write consumes its item")
    check(queueProvider.requests == 0, "prepareNextQueuedPaste does not request delayed old clipboard data")

    pasteboard.clearContents()
    pasteboard.setString("no rollback promised", forType: textType)
    check(ClipboardWrite.attempt([replacement()], to: pasteboard, using: { _, _ in false }) == .writeFailed, "ordinary write failure has a distinct result without a rollback promise")
    check(pasteboard.types?.isEmpty != false, "ordinary write failure leaves the post-clear clipboard state observable")

    let partlyReadableForRecovery = item([(textType.rawValue, Data("readable recovery text".utf8))])
    check(partlyReadableForRecovery.setDataProvider(missingProvider, forTypes: [unreadableType]), "explicit recovery fixture declares an unreadable representation")
    pasteboard.clearContents()
    check(pasteboard.writeObjects([partlyReadableForRecovery]), "explicit recovery fixture is writable")
    check(ClipboardWrite.attempt([replacement()], to: pasteboard, failureRecovery: .restorePrevious, using: { _, _ in false }) == .restoreFailed, "incomplete explicit rollback reports restoration failure")
    check(pasteboard.string(forType: textType) == "readable recovery text", "incomplete explicit rollback still restores its readable representation")

    let replacingProvider = ReplacingPasteboardDataProvider()
    let changingItem = NSPasteboardItem()
    check(changingItem.setDataProvider(replacingProvider, forTypes: [unreadableType]), "fixture installs ownership-changing provider")
    pasteboard.clearContents()
    check(pasteboard.writeObjects([changingItem]), "ownership-changing fixture is writable")
    check(ClipboardWrite.attempt([replacement()], to: pasteboard) == .written, "ordinary write does not invoke an ownership-changing old provider")
    check(pasteboard.string(forType: textType) == "after", "ordinary write installs the requested content without reading old content")

    pasteboard.clearContents()
    pasteboard.setString("newer than expected", forType: textType)
    let currentCount = pasteboard.changeCount
    check(ClipboardWrite.attempt([replacement()], to: pasteboard, expectedChangeCount: currentCount - 1) == .superseded, "ordinary write rejects a stale expected clipboard version")
    check(pasteboard.changeCount == currentCount && pasteboard.string(forType: textType) == "newer than expected", "stale expected version is rejected before clearing content")

    let originalText = Data("original".utf8)
    let originalCustom = Data([0, 1, 2, 3, 255])
    let secondValue = Data([9, 8, 7])
    pasteboard.clearContents()
    pasteboard.writeObjects([
        item([(textType.rawValue, originalText), (customType.rawValue, originalCustom)]),
        item([(secondType.rawValue, secondValue)])
    ])
    let failureStartCount = pasteboard.changeCount
    let failed = ClipboardWrite.attempt([replacement()], to: pasteboard, failureRecovery: .restorePrevious, using: { _, _ in false })
    check(failed == .restoredPrevious, "explicit recovery reports successful rollback")
    let restored = pasteboard.pasteboardItems ?? []
    check(restored.count == 2 && restored[0].data(forType: textType) == originalText && restored[0].data(forType: customType) == originalCustom && restored[1].data(forType: secondType) == secondValue, "explicit recovery restores every old item and representation")
    check(pasteboard.changeCount == failureStartCount + 1, "rollback writes directly to the already-cleared pasteboard")

    pasteboard.clearContents()
    pasteboard.setString("old owner", forType: textType)
    let raced = ClipboardWrite.attempt([replacement()], to: pasteboard, using: { board, _ in
        board.clearContents()
        board.setString("new external copy", forType: textType)
        return false
    })
    check(raced == .superseded, "injected failure detects a concurrent clipboard owner")
    check(pasteboard.string(forType: textType) == "new external copy", "newer clipboard content is not overwritten by rollback")

    pasteboard.clearContents()
    pasteboard.setString("old owner", forType: textType)
    let explicitRace = ClipboardWrite.attempt([replacement()], to: pasteboard, failureRecovery: .restorePrevious, using: { board, _ in
        board.clearContents()
        board.setString("new external copy during explicit recovery", forType: textType)
        return false
    })
    check(explicitRace == .superseded, "explicit recovery detects a concurrent clipboard owner")
    check(pasteboard.string(forType: textType) == "new external copy during explicit recovery", "explicit recovery does not overwrite newer external content")

    pasteboard.clearContents()
    pasteboard.writeObjects([item([(textType.rawValue, originalText), (customType.rawValue, originalCustom)])])
    let snapshot = ClipboardWrite.snapshot(pasteboard)!
    pasteboard.clearContents()
    pasteboard.setString("temporary selection", forType: textType)
    let temporaryCount = pasteboard.changeCount
    check(ClipboardWrite.restore(snapshot, to: pasteboard, expectedChangeCount: temporaryCount) == .written, "complete snapshot can restore the owned temporary clipboard")
    check(pasteboard.string(forType: textType) == "original" && pasteboard.data(forType: customType) == originalCustom, "snapshot restoration preserves every original representation")

    pasteboard.clearContents()
    pasteboard.writeObjects([item([(textType.rawValue, originalText), (customType.rawValue, originalCustom)])])
    let staleSnapshot = ClipboardWrite.snapshot(pasteboard)!
    pasteboard.clearContents()
    pasteboard.setString("temporary selection", forType: textType)
    let staleCount = pasteboard.changeCount
    pasteboard.clearContents()
    pasteboard.setString("new external copy after observation", forType: textType)
    check(ClipboardWrite.restore(staleSnapshot, to: pasteboard, expectedChangeCount: staleCount) == .superseded, "stale restoration ownership is rejected")
    check(pasteboard.string(forType: textType) == "new external copy after observation", "stale restoration does not replace newer clipboard content")

    pasteboard.clearContents()
    pasteboard.writeObjects([item([(textType.rawValue, originalText), (customType.rawValue, originalCustom)])])
    let failureSnapshot = ClipboardWrite.snapshot(pasteboard)!
    pasteboard.clearContents()
    pasteboard.setString("temporary selection", forType: textType)
    let restoreFailureCount = pasteboard.changeCount
    let restoreFailure = ClipboardWrite.restore(failureSnapshot, to: pasteboard, expectedChangeCount: restoreFailureCount, using: { _, _ in false })
    check(restoreFailure == .restoredPrevious && pasteboard.string(forType: textType) == "temporary selection", "failed restoration puts the owned temporary content back")

    pasteboard.clearContents()
    let emptySnapshot = ClipboardWrite.snapshot(pasteboard)!
    pasteboard.setString("temporary selection", forType: textType)
    check(ClipboardWrite.restore(emptySnapshot, to: pasteboard, expectedChangeCount: pasteboard.changeCount) == .written, "an originally empty clipboard can be restored")
    check(pasteboard.types?.isEmpty != false, "empty restoration removes the temporary selection")

    // NSPasteboard exposes no cross-process compare-and-swap operation. These tests
    // cover observable ownership changes, not the unavoidable interval between the
    // final changeCount check and the destructive system call.

    print("\(checks) clipboard write tests passed")
}
