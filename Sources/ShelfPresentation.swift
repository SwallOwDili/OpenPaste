import AppKit
import SwiftUI
import Combine

struct CardPresentationKey: Equatable, Sendable {
    let id: UUID
    let digest: String?
    let uncachedPartTypes: [String]
    let text: String
    let kind: String
    let directory: Int
    init(clip: Clip, directory: Int) {
        id = clip.id; digest = clip.cachedDigest; text = clip.text; kind = clip.kind; self.directory = directory
        // Unsaved/test clips can lack a content digest. Their representation still
        // determines HTML fallback and rich-text classification without hashing bytes.
        uncachedPartTypes = clip.cachedDigest == nil ? Set(clip.parts.flatMap { $0.map(\.type) }).sorted() : []
    }
}
/// Immutable after construction; attributed strings are never mutated after publication.
struct CardPresentation: @unchecked Sendable {
    let summary: String
    let language: String?
    let color: CapturedColor?
    let isMap: Bool
    let richText: Bool
    let characterCountLabel: String?
    let highlighted: NSAttributedString?
}
/// A cancelled SwiftUI task releases its continuation and queued clip immediately.
/// Both continuation installation and cancellation are serialized by this lock.
private final class CardPresentationTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CardPresentation?, Never>?
    private var completed = false
    func install(_ value: CheckedContinuation<CardPresentation?, Never>) -> Bool {
        lock.lock()
        guard !completed else { lock.unlock(); value.resume(returning: nil); return false }
        continuation = value; lock.unlock(); return true
    }
    func finish(_ value: CardPresentation?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let callback = continuation; continuation = nil
        lock.unlock(); callback?.resume(returning: value)
    }
    var isCompleted: Bool { lock.lock(); defer { lock.unlock() }; return completed }
}

/// All mutable state is lock-protected; only one worker parses at a time. Published
/// values are immutable. The dispatch queue holds one drain closure, never one Clip
/// closure per request, so cancellation actually bounds retained work and payloads.
final class CardPresentationCache: @unchecked Sendable {
    static let shared = CardPresentationCache()
    private final class Job {
        let key: CardPresentationKey
        let clip: Clip
        let retainedBytes: Int
        var tickets: [CardPresentationTicket]
        init(key: CardPresentationKey, clip: Clip, ticket: CardPresentationTicket) {
            self.key = key; self.clip = clip; retainedBytes = clip.text.utf8.count + clip.byteCount; tickets = [ticket]
        }
    }
    private let queue = DispatchQueue(label: "openpaste.card-presentation", qos: .userInitiated)
    private let lock = NSLock()
    private var cache: [UUID: (CardPresentationKey, CardPresentation, Int)] = [:]
    private var cacheOrder: [UUID] = []
    private var cacheBytes = 0
    private var pending: [Job] = []
    private var running: Job?
    private var draining = false
    private let pendingLimit = 64
    private let pendingByteLimit = 8 * 1024 * 1024
    private var pendingBytes = 0
    private var preparations = 0
    private let beforePrepare: (@Sendable () -> Void)?
    init(beforePrepare: (@Sendable () -> Void)? = nil) { self.beforePrepare = beforePrepare }
    #if OPENPASTE_TESTING
    struct Statistics {
        let queuedCount: Int
        let queuedBytes: Int
        let runningCount: Int
        let preparationCount: Int
    }
    var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        return Statistics(queuedCount: pending.count, queuedBytes: pendingBytes, runningCount: running == nil ? 0 : 1, preparationCount: preparations)
    }
    #endif

    func value(for clip: Clip, directory: Int) async -> CardPresentation? {
        let ticket = CardPresentationTicket()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard ticket.install(continuation) else { return }
                enqueue(clip, directory: directory, ticket: ticket)
            }
        }, onCancel: { self.cancel(ticket) })
    }
    private func enqueue(_ clip: Clip, directory: Int, ticket: CardPresentationTicket) {
        let key = CardPresentationKey(clip: clip, directory: directory)
        var discarded: [CardPresentationTicket] = []
        lock.lock()
        guard !ticket.isCompleted else { lock.unlock(); return }
        if let entry = cache[clip.id], entry.0 == key {
            lock.unlock(); ticket.finish(entry.1); return
        }
        if let job = running, job.key == key, !job.tickets.isEmpty {
            job.tickets.append(ticket); lock.unlock(); return
        }
        if let job = pending.first(where: { $0.key == key }) {
            job.tickets.append(ticket); lock.unlock(); return
        }
        // A newer version supersedes queued work for the same clip. The cap also
        // protects fast navigation through a large shelf with expensive text.
        if let index = pending.firstIndex(where: { $0.key.id == clip.id }) {
            let old = pending.remove(at: index)
            pendingBytes -= old.retainedBytes; discarded += old.tickets
        }
        let bytes = clip.text.utf8.count + clip.byteCount
        while !pending.isEmpty && (pending.count >= pendingLimit || pendingBytes + bytes > pendingByteLimit) {
            let old = pending.removeFirst()
            pendingBytes -= old.retainedBytes; discarded += old.tickets
        }
        // Oversized clips keep their cheap card summary; presentation metadata is
        // optional and must not retain an unbounded payload in the preview queue.
        if bytes <= pendingByteLimit {
            pending.append(Job(key: key, clip: clip, ticket: ticket)); pendingBytes += bytes
        } else { discarded.append(ticket) }
        let start = !draining && !pending.isEmpty
        if start { draining = true }
        lock.unlock()
        discarded.forEach { $0.finish(nil) }
        if start { queue.async { self.drain() } }
    }
    private func cancel(_ ticket: CardPresentationTicket) {
        ticket.finish(nil)
        lock.lock()
        running?.tickets.removeAll { $0 === ticket }
        for index in pending.indices.reversed() {
            pending[index].tickets.removeAll { $0 === ticket }
            if pending[index].tickets.isEmpty {
                pendingBytes -= pending[index].retainedBytes
                pending.remove(at: index)
            }
        }
        lock.unlock()
    }
    private func wanted(_ job: Job) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return job.tickets.contains { !$0.isCompleted }
    }
    private func beginPreparation(_ job: Job) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard job.tickets.contains(where: { !$0.isCompleted }) else { return false }
        preparations += 1
        return true
    }
    private func nextJob() -> Job? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { draining = false; running = nil; return nil }
        let job = pending.removeFirst(); pendingBytes -= job.retainedBytes
        running = job; return job
    }
    private func drain() {
        while let job = nextJob() {
            beforePrepare?()
            let value: CardPresentation? = autoreleasepool {
                guard beginPreparation(job) else { return nil }
                let clip = job.clip
                let htmlOnly = RichTextCache.hasRichPart(clip) && !RichTextCache.hasShelfRichPart(clip)
                let language = clip.kind == "文字" && !htmlOnly ? CodeSyntax.language(clip.text) : nil
                guard wanted(job) else { return nil }
                let color = CapturedColor.parse(clip.text)
                let summary = String(clip.text.prefix(language == nil ? 1500 : 3000))
                let count = clip.kind == "文字" ? (clip.text.utf8.count > 200_000 ? "20 万+ 字符" : "\(clip.text.count) 个字符") : nil
                guard wanted(job) else { return nil }
                let richText = clip.kind == "文字" && language == nil && color == nil && RichTextCache.hasShelfRichPart(clip)
                return CardPresentation(summary: summary, language: language, color: color, isMap: MapLink.parse(clip.text) != nil, richText: richText, characterCountLabel: count, highlighted: language == nil ? nil : CodeSyntax.highlighted(summary))
            }
            lock.lock()
            let tickets = job.tickets; job.tickets.removeAll(); running = nil
            if let value, tickets.contains(where: { !$0.isCompleted }) {
                if let old = cache.removeValue(forKey: job.key.id) { cacheBytes -= old.2 }
                cacheOrder.removeAll { $0 == job.key.id }
                let cost = job.key.text.utf8.count + value.summary.utf8.count + (value.highlighted?.length ?? 0) * 8
                while !cacheOrder.isEmpty && (cache.count >= 256 || cacheBytes + cost > 16 * 1024 * 1024) {
                    let id = cacheOrder.removeFirst()
                    if let old = cache.removeValue(forKey: id) { cacheBytes -= old.2 }
                }
                if cost <= 16 * 1024 * 1024 { cache[job.key.id] = (job.key, value, cost); cacheOrder.append(job.key.id); cacheBytes += cost }
            }
            lock.unlock()
            tickets.forEach { $0.finish(value) }
        }
    }
}

/// Only result/selection/display changes invalidate the shelf's card tree. OCR status
/// and text-field draft notifications belong to their own views.
final class ShelfResultsObservation: ObservableObject {
    let store: Store
    private var subscriptions = Set<AnyCancellable>()
    init(store: Store) {
        self.store = store
        func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
            publisher.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        observe(store.$searchAppliedGeneration); observe(store.$searchPending); observe(store.$searchInputIsComposing)
        observe(store.$selected); observe(store.$selection); observe(store.$compact)
        observe(store.$currentClipID); observe(store.$renamingID); observe(store.$networkPreviews)
        observe(store.$translating); observe(store.$changingDataDirectory)
    }
}
struct ShelfResultsView: View, Equatable {
    let store: Store
    @StateObject private var observation: ShelfResultsObservation
    @State private var renderedClipCount = ShelfRenderWindow.batchSize
    @State private var previewsReady = false
    init(store: Store) { self.store = store; _observation = StateObject(wrappedValue: ShelfResultsObservation(store: store)) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.store === rhs.store }
    private var pending: Bool { store.searchPending || store.searchInputIsComposing }
    var body: some View {
        let _ = observation.store
        let rendered = Array(store.filtered.prefix(renderedClipCount))
        // ForEach retains its content closure across renders. Capture immutable
        // inputs here, rather than letting old/new closures both read the same
        // @State storage when SwiftUI compares their child cards lazily.
        let cardPreviewsReady = previewsReady && !pending
        let previewGeneration = store.searchAppliedGeneration
        let directoryGeneration = store.storageCallbackGeneration
        Group {
            if store.filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 35)).foregroundStyle(.tertiary)
                    Text(pending ? "正在搜索…" : (store.query.isEmpty ? "复制一些内容，它们会出现在这里" : "没有找到“\(store.query)”")).foregroundStyle(.secondary)
                    Text("搜索文字、链接和来源应用；图片文字将在后台识别后加入搜索").font(.system(size: 12)).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 12) {
                            if store.translating { VStack(spacing: 12) { ProgressView(); Text("正在翻译…"); Text("原文保持不变").font(.caption).foregroundStyle(.secondary) }.frame(width: store.compact ? 180 : 240).frame(maxHeight: .infinity).background(.quaternary, in: RoundedRectangle(cornerRadius: 12)) }
                            ForEach(rendered) { clip in
                                ClipCard(clip: clip, index: store.visibleIndex(of: clip.id) ?? 0, selected: store.selection.contains(clip.id) || clip.id == store.selected, current: clip.id == store.currentClipID, renaming: store.renamingID == clip.id, compact: store.compact, networkPreviews: store.networkPreviews, previewGeneration: previewGeneration, previewsReady: cardPreviewsReady, directoryGeneration: directoryGeneration, store: store).equatable().id(clip.id)
                                    .onAppear { if clip.id == rendered.last?.id { renderedClipCount = ShelfRenderWindow.nextCount(current: renderedClipCount, total: store.filtered.count) } }
                            }
                        }.padding(.horizontal, 20).padding(.vertical, 8)
                    }.onChange(of: store.selected) { _, id in
                        guard let id, let index = store.visibleIndex(of: id) else { return }
                        renderedClipCount = max(renderedClipCount, ShelfRenderWindow.countIncluding(index: index, total: store.filtered.count))
                        DispatchQueue.main.async { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .onChange(of: store.searchAppliedGeneration) { _, _ in
            renderedClipCount = ShelfRenderWindow.resetCount(total: store.filtered.count, selectedIndex: store.selected.flatMap { store.visibleIndex(of: $0) })
        }
        .task(id: PreviewReadiness(generation: store.searchAppliedGeneration, pending: pending)) {
            AcceptanceMetrics.searchEvent(pending ? "preview-gate.pending" : "preview-gate.wait", generation: store.searchAppliedGeneration, count: store.filtered.count, milliseconds: 0)
            previewsReady = false
            guard !pending else { return }
            // Results paint first; this wait gates optional previews, never query submission.
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, !store.searchPending, !store.searchInputIsComposing else {
                AcceptanceMetrics.searchEvent("preview-gate.cancelled", generation: store.searchAppliedGeneration, count: store.filtered.count, milliseconds: 0)
                return
            }
            previewsReady = true
            AcceptanceMetrics.searchEvent("preview-gate.ready", generation: store.searchAppliedGeneration, count: store.filtered.count, milliseconds: 0)
        }
    }
}
private struct PreviewReadiness: Equatable { let generation: Int; let pending: Bool }
