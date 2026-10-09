import AppKit

enum QueuedPasteResult { case ready, empty, failed }

extension Store {
    func discardMissingQueueItems() {
        guard !pasteQueue.isEmpty else { return }
        let available = Set(archive.clips.map(\.id))
        let remaining = pasteQueue.filter { available.contains($0) }
        if remaining != pasteQueue { pasteQueue = remaining }
    }

    // Queue entries refer to current content. A successful clipboard write
    // consumes one entry even when the user must finish with manual Command-V.
    func prepareNextQueuedPaste(pasteboard: NSPasteboard = .general) -> QueuedPasteResult {
        discardMissingQueueItems()
        guard let id = pasteQueue.first,
              let clip = archive.clips.first(where: { $0.id == id }) else { return .empty }
        guard restore(clip, plain: false, pasteboard: pasteboard) else { return .failed }
        pasteQueue.removeFirst()
        return .ready
    }
}
