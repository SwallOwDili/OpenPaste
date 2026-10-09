import AppKit

func runPasteQueueTests() {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { print("FAIL: \(label)"); exit(1) }
        checks += 1; print("PASS: \(label)")
    }
    func textClip(_ value: String) -> Clip {
        Clip(source: "Fixture", sourceID: "example.queue", kind: "文字", title: value, text: value,
             parts: [[ClipPart(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(value.utf8))]])
    }
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let store = Store(ephemeral: true)
    let a = textClip("Queue A"), b = textClip("Queue B"), c = textClip("Queue C")
    store.archive.clips = [a, b, c]
    store.pasteQueue = [a.id, b.id, c.id]
    store.delete(b.id)
    check(store.pasteQueue == [a.id, c.id], "deleting a queued item immediately fixes remaining count")
    store.undoItemChange()
    check(store.pasteQueue == [a.id, c.id] && store.archive.clips.count == 3, "undo restores history without silently requeueing an item")
    check(store.prepareNextQueuedPaste(pasteboard: board) == .ready && board.string(forType: .string) == a.text, "first queue item writes original content")
    check(store.pasteQueue == [c.id], "successful clipboard write consumes exactly one entry")
    var edited = c
    edited.text = "Queue C edited"; edited.parts = [[ClipPart(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(edited.text.utf8))]]
    store.replace(edited, label: "编辑")
    check(store.prepareNextQueuedPaste(pasteboard: board) == .ready && board.string(forType: .string) == edited.text, "queue resolves current edited content without changing queue order")
    check(store.pasteQueue.isEmpty && store.prepareNextQueuedPaste(pasteboard: board) == .empty, "finished queue remains empty on repeated next")
    let invalid = Clip(source: "Fixture", sourceID: "example.queue", kind: "图片", title: "Missing payload", text: "", parts: [])
    store.archive.clips.append(invalid); store.pasteQueue = [invalid.id, a.id]
    let count = board.changeCount
    let historyBeforeFailure = store.archive.clips.map(\.id)
    check(store.prepareNextQueuedPaste(pasteboard: board) == .failed, "missing clipboard payload reports failure")
    check(store.pasteQueue == [invalid.id, a.id] && board.changeCount == count, "failed entry and previous clipboard survive for retry")
    check(store.archive.clips.map(\.id) == historyBeforeFailure, "failed queue write does not reorder history")
    store.delete(invalid.id)
    check(store.prepareNextQueuedPaste(pasteboard: board) == .ready && board.string(forType: .string) == a.text, "removing failed item allows next entry to continue")
    store.pasteQueue = [UUID(), a.id, a.id]
    check(store.prepareNextQueuedPaste(pasteboard: board) == .ready && store.pasteQueue == [a.id], "stale references are skipped and repeated references consume one at a time")
    store.clearHistory()
    check(store.pasteQueue.isEmpty, "clearing unpinned history also clears its queue entries")
    print("\(checks) paste queue tests passed")
}
