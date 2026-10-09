import AppKit

enum ClipboardWrite {
    typealias Writer = (NSPasteboard, [NSPasteboardItem]) -> Bool
    enum FailureRecovery {
        case none
        case restorePrevious
    }
    struct Snapshot {
        fileprivate let items: [NSPasteboardItem]
        let changeCount: Int
        fileprivate let isComplete: Bool
    }
    enum Outcome: Equatable {
        case written
        case rejected
        case writeFailed
        case restoredPrevious
        case superseded
        case restoreFailed

        var succeeded: Bool { self == .written }
    }

    static func snapshot(_ pasteboard: NSPasteboard, requireComplete: Bool = true) -> Snapshot? {
        let changeCount = pasteboard.changeCount
        guard let sources = pasteboard.pasteboardItems else {
            let complete = pasteboard.types?.isEmpty != false
            guard pasteboard.changeCount == changeCount else { return nil }
            return requireComplete && !complete ? nil : Snapshot(items: [], changeCount: changeCount, isComplete: complete)
        }
        var items: [NSPasteboardItem] = []
        var complete = true
        for source in sources {
            guard !source.types.isEmpty else {
                complete = false
                if requireComplete { return nil }
                continue
            }
            let item = NSPasteboardItem()
            for type in source.types {
                guard let data = source.data(forType: type), item.setData(data, forType: type) else {
                    complete = false
                    if requireComplete { return nil }
                    continue
                }
            }
            if item.types.isEmpty { complete = false } else { items.append(item) }
        }
        guard pasteboard.changeCount == changeCount else { return nil }
        return Snapshot(items: items, changeCount: changeCount, isComplete: complete)
    }

    static func attempt(
        _ items: [NSPasteboardItem],
        to pasteboard: NSPasteboard,
        expectedChangeCount: Int? = nil,
        failureRecovery: FailureRecovery = .none,
        using writer: Writer = { pasteboard, items in pasteboard.writeObjects(items) }
    ) -> Outcome {
        guard !items.isEmpty, items.allSatisfy({ !$0.types.isEmpty }) else { return .rejected }
        let previous: Snapshot?
        switch failureRecovery {
        case .none:
            previous = nil
        case .restorePrevious:
            guard let captured = snapshot(pasteboard, requireComplete: false) else { return .superseded }
            previous = captured
        }
        // NSPasteboard has no cross-process compare-and-swap operation. Keeping the
        // version check adjacent to clearContents narrows, but cannot remove, the
        // interval in which another process could take ownership.
        guard expectedChangeCount.map({ pasteboard.changeCount == $0 }) ?? true else { return .superseded }
        let clearedChangeCount = pasteboard.clearContents()
        guard writer(pasteboard, items) else {
            // A changed count means another owner wrote after our clear/failure.
            // Restoring here would overwrite that newer clipboard content.
            guard pasteboard.changeCount == clearedChangeCount else { return .superseded }
            guard let previous else { return .writeFailed }
            guard !previous.items.isEmpty else { return previous.isComplete ? .restoredPrevious : .restoreFailed }
            // The board is already empty and still has our clear's change count. Avoid
            // opening another check/clear window before putting the snapshot back.
            return pasteboard.writeObjects(previous.items) && previous.isComplete ? .restoredPrevious : .restoreFailed
        }
        return .written
    }

    static func restore(
        _ snapshot: Snapshot,
        to pasteboard: NSPasteboard,
        expectedChangeCount: Int,
        using writer: Writer = { pasteboard, items in pasteboard.writeObjects(items) }
    ) -> Outcome {
        guard pasteboard.changeCount == expectedChangeCount else { return .superseded }
        if snapshot.items.isEmpty {
            // NSPasteboard has no compare-and-swap operation. This ownership check is
            // intentionally adjacent to the destructive call, but another process can
            // still win the unavoidable interval between them.
            guard pasteboard.changeCount == expectedChangeCount else { return .superseded }
            pasteboard.clearContents()
            return .written
        }
        return attempt(
            snapshot.items,
            to: pasteboard,
            expectedChangeCount: expectedChangeCount,
            failureRecovery: .restorePrevious,
            using: writer
        )
    }

    static func write(
        _ items: [NSPasteboardItem],
        to pasteboard: NSPasteboard,
        using writer: Writer = { pasteboard, items in pasteboard.writeObjects(items) }
    ) -> Bool {
        attempt(items, to: pasteboard, using: writer).succeeded
    }
}
