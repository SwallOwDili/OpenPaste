import Foundation

/// Selection is resolved against the installed result, never the previous query's rows.
enum SearchSelectionIntent {
    case preserve
    case first
    case preferred(UUID?)
    /// Programmatic choice after insertion replaces any previous multi-selection.
    case single(UUID)
    case neighbor(Int)
}

struct SearchCriteria {
    var query: String
    var board: UUID?
    var kind: String
    var source: String
    var todayStart: Date?
    var todayEnd: Date?
    var rangeStart: Date?
    var rangeEnd: Date?
    var reversed: Bool

    var hasMetadataFilters: Bool {
        board != nil || kind != "全部" || source != "全部来源" || todayStart != nil || rangeStart != nil
    }

    func includesMetadata(_ clip: Clip) -> Bool {
        (board == nil || clip.boards.contains(board!)) &&
        (kind == "全部" || clip.kind == kind) &&
        (source == "全部来源" || clip.source == source) &&
        (todayStart == nil || (clip.created >= todayStart! && clip.created < todayEnd!)) &&
        (rangeStart == nil || (clip.created >= rangeStart! && clip.created < rangeEnd!))
    }
}

struct SearchRequest {
    let generation: Int
    let archiveRevision: Int
    let storageGeneration: Int
    let sourcesRevision: Int
    let clips: [Clip]
    let criteria: SearchCriteria
    let submittedAt: TimeInterval
}

struct SearchResult {
    let generation: Int
    let archiveRevision: Int
    let storageGeneration: Int
    let clips: [Clip]
    let indexByID: [UUID: Int]
    let sources: [String]
    let submittedAt: TimeInterval
}

/// Aggregate-only diagnostics; no history identifiers, queries, or text escape.
struct SearchCacheStatistics {
    let documentCount: Int
    let orderedDocumentCount: Int
    let nativeUTF16CodeUnitCount: Int
}

private final class SearchCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Native immutable Foundation strings avoid repeatedly bridging entire Swift strings
/// during localized matching. The original strings remain the cache version key.
private final class SearchDocument {
    let fields: [String]
    let nativeFields: [NSString]
    let nativeUTF16CodeUnitCount: Int

    init(fields: [String]) {
        self.fields = fields
        // Empty fields cannot match a nonempty query. Try short fields before a
        // potentially large body; OR matching does not depend on field order.
        nativeFields = fields.filter { !$0.isEmpty }.map { value in
            let units = Array(value.utf16)
            return units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return NSString() }
                return NSString(characters: base, length: buffer.count)
            }
        }.sorted { $0.length < $1.length }
        nativeUTF16CodeUnitCount = nativeFields.reduce(0) { $0 + $1.length }
    }

    static func fields(for clip: Clip) -> [String] {
        [clip.title, clip.text, clip.source, clip.ocrText ?? "", clip.linkTitle ?? "", clip.userLabel ?? ""]
    }

    func matches(_ query: String) -> Bool {
        // Literal scalar checks can reject canonically equivalent kana, Hangul,
        // and CJK compatibility ideographs before Foundation can match them.
        nativeFields.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// Only the worker queue touches prepared documents. A lock protects admission so
/// cancelling a running request does not wait behind its scan on that queue.
final class SearchPipeline {
    static let maximumWorkers = 4
    static let batchSize = 128
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "openpaste.search", qos: .userInitiated)
    private let workers = DispatchQueue(label: "openpaste.search.workers", qos: .userInitiated, attributes: .concurrent)
    private var running = false
    private var activeCancellation: SearchCancellation?
    private var latest: (SearchRequest, (SearchResult) -> Void)?
    private var documentsByID: [UUID: SearchDocument] = [:]
    private var documents: [SearchDocument] = []
    private var preparedArchiveRevision = -1
    private var cachedMembershipRevision = -1
    private var preparedStorageGeneration = -1
    private var preparedSourcesRevision = -1
    private var sources: [String] = []
    private let beforeScan: ((SearchRequest) -> Void)?
    private let beforePreparingFirstDocument: ((SearchRequest) -> Void)?
    private let statisticsLock = NSLock()
    private var cacheStatistics = SearchCacheStatistics(documentCount: 0, orderedDocumentCount: 0, nativeUTF16CodeUnitCount: 0)

    /// Read from any thread; wait for the latest result before asserting cleanup.
    var debugCacheStatistics: SearchCacheStatistics {
        statisticsLock.lock(); defer { statisticsLock.unlock() }
        return cacheStatistics
    }

    /// An internal scheduling seam for deterministic cancellation tests. Runs on
    /// the coordinator queue, never the main thread; production leaves it nil.
    init(beforeScan: ((SearchRequest) -> Void)? = nil,
         beforePreparingFirstDocument: ((SearchRequest) -> Void)? = nil) {
        self.beforeScan = beforeScan
        self.beforePreparingFirstDocument = beforePreparingFirstDocument
    }

    func submit(_ request: SearchRequest, completion: @escaping (SearchResult) -> Void) {
        lock.lock()
        activeCancellation?.cancel()
        latest = (request, completion)
        let shouldStart = !running
        if shouldStart { running = true }
        lock.unlock()
        if shouldStart { queue.async { self.drain() } }
    }

    func cancel() {
        lock.lock()
        activeCancellation?.cancel()
        latest = nil
        lock.unlock()
    }

    private func drain() {
        while true {
            lock.lock()
            guard let (request, completion) = latest else {
                // Retain the last token until the next admission: its result may
                // still be waiting on the main queue when a new query arrives.
                running = false
                lock.unlock()
                return
            }
            latest = nil
            let cancellation = SearchCancellation()
            activeCancellation = cancellation
            lock.unlock()
            autoreleasepool {
                guard let result = execute(request, cancellation: cancellation), !cancellation.isCancelled else { return }
                DispatchQueue.main.async {
                    guard !cancellation.isCancelled else { return }
                    completion(result)
                }
            }
        }
    }

    private func prepare(_ request: SearchRequest, cancellation: SearchCancellation) -> Bool {
        var cacheChanged = false
        defer {
            if cacheChanged {
                let snapshot = SearchCacheStatistics(documentCount: documentsByID.count, orderedDocumentCount: documents.count,
                                                     nativeUTF16CodeUnitCount: documentsByID.values.reduce(0) { $0 + $1.nativeUTF16CodeUnitCount })
                statisticsLock.lock(); cacheStatistics = snapshot; statisticsLock.unlock()
            }
        }
        if preparedStorageGeneration != request.storageGeneration {
            documentsByID.removeAll()
            documents.removeAll()
            sources.removeAll()
            preparedArchiveRevision = -1
            cachedMembershipRevision = -1
            preparedSourcesRevision = -1
            preparedStorageGeneration = request.storageGeneration
            cacheChanged = true
        }
        if request.criteria.query.isEmpty, cachedMembershipRevision != request.archiveRevision {
            // Clearing the query does not end cache ownership. Deletions and
            // edits while browsing still release removed/obsolete text copies.
            documents.removeAll()
            preparedArchiveRevision = -1
            cacheChanged = true
            var retained: [UUID: SearchDocument] = [:]
            if !request.clips.isEmpty, !documentsByID.isEmpty {
                retained.reserveCapacity(min(request.clips.count, documentsByID.count))
                for clip in request.clips {
                    if cancellation.isCancelled { return false }
                    if let cached = documentsByID[clip.id], cached.fields == SearchDocument.fields(for: clip) {
                        retained[clip.id] = cached
                    }
                }
            }
            documentsByID = retained
            cachedMembershipRevision = request.archiveRevision
        }
        // Opening or clearing the shelf needs only metadata. Do not delay its
        // first result by preparing text that this request will never inspect.
        if !request.criteria.query.isEmpty, preparedArchiveRevision != request.archiveRevision {
            // The immutable previous cache can be read by all workers. Publish
            // newly prepared documents only after the group joins; partial work
            // remains reusable when a newer request cancels this preparation.
            let previousByID = documentsByID
            let preparation = SearchPreparation(count: request.clips.count)
            let group = DispatchGroup()
            let workerCount = min(Self.maximumWorkers, max(1, (request.clips.count + Self.batchSize - 1) / Self.batchSize))
            for _ in 0..<workerCount {
                group.enter()
                workers.async {
                    defer { group.leave() }
                    while !cancellation.isCancelled, let range = preparation.take() {
                        var batch: [(Int, SearchDocument)] = []
                        batch.reserveCapacity(range.count)
                        for index in range {
                            if index == 0 { self.beforePreparingFirstDocument?(request) }
                            if cancellation.isCancelled { break }
                            let clip = request.clips[index]
                            let fields = SearchDocument.fields(for: clip)
                            let document: SearchDocument
                            if let cached = previousByID[clip.id], cached.fields == fields { document = cached }
                            else { document = SearchDocument(fields: fields) }
                            batch.append((index, document))
                        }
                        preparation.append(batch)
                    }
                }
            }
            group.wait()
            var prepared: [SearchDocument] = []
            var currentByID: [UUID: SearchDocument] = [:]
            prepared.reserveCapacity(request.clips.count)
            currentByID.reserveCapacity(request.clips.count)
            for (index, document) in preparation.documents.enumerated() {
                guard let document else { continue }
                prepared.append(document)
                currentByID[request.clips[index].id] = document
            }
            cacheChanged = true
            if cancellation.isCancelled {
                documentsByID.merge(currentByID) { _, new in new }
                return false
            }
            documents = prepared
            documentsByID = currentByID
            preparedArchiveRevision = request.archiveRevision
            cachedMembershipRevision = request.archiveRevision
            cacheChanged = true
        }
        if preparedSourcesRevision != request.sourcesRevision {
            var values = Set<String>()
            for clip in request.clips {
                if cancellation.isCancelled { return false }
                values.insert(clip.source)
            }
            sources = values.sorted()
            preparedSourcesRevision = request.sourcesRevision
        }
        return !cancellation.isCancelled
    }

    private func execute(_ request: SearchRequest, cancellation: SearchCancellation) -> SearchResult? {
        let startedAt = ProcessInfo.processInfo.systemUptime
        AcceptanceMetrics.searchEvent("queue", generation: request.generation, count: request.clips.count,
                                      milliseconds: (startedAt - request.submittedAt) * 1000)
        guard prepare(request, cancellation: cancellation) else { return nil }
        beforeScan?(request)
        guard !cancellation.isCancelled else { return nil }
        let preparedAt = ProcessInfo.processInfo.systemUptime
        AcceptanceMetrics.searchEvent("prepare", generation: request.generation, count: request.clips.count,
                                      milliseconds: (preparedAt - startedAt) * 1000)
        let snapshot = documents
        let query = request.criteria.query
        let hasMetadataFilters = request.criteria.hasMetadataFilters
        let chunks = SearchChunks(count: request.clips.count)
        let group = DispatchGroup()
        let workerCount = min(Self.maximumWorkers, max(1, (request.clips.count + Self.batchSize - 1) / Self.batchSize))
        for _ in 0..<workerCount {
            group.enter()
            workers.async {
                defer { group.leave() }
                while !cancellation.isCancelled, let range = chunks.take() {
                    var matching: [Int] = []
                    for index in range {
                        if cancellation.isCancelled { return }
                        if hasMetadataFilters && !request.criteria.includesMetadata(request.clips[index]) { continue }
                        if query.isEmpty || snapshot[index].matches(query) { matching.append(index) }
                    }
                    chunks.append(matching)
                }
            }
        }
        group.wait()
        guard !cancellation.isCancelled else { return nil }
        var indices = chunks.matches.sorted()
        if request.criteria.reversed { indices.reverse() }
        var result: [Clip] = []
        var indexByID: [UUID: Int] = [:]
        result.reserveCapacity(indices.count)
        indexByID.reserveCapacity(indices.count)
        for index in indices {
            if cancellation.isCancelled { return nil }
            let clip = request.clips[index]
            if indexByID[clip.id] == nil { indexByID[clip.id] = result.count }
            result.append(clip)
        }
        AcceptanceMetrics.searchEvent("match-and-index", generation: request.generation, count: result.count,
                                      milliseconds: (ProcessInfo.processInfo.systemUptime - preparedAt) * 1000)
        return SearchResult(generation: request.generation, archiveRevision: request.archiveRevision,
                            storageGeneration: request.storageGeneration, clips: result, indexByID: indexByID,
                            sources: sources, submittedAt: request.submittedAt)
    }
}

private final class SearchChunks {
    private let lock = NSLock()
    private let count: Int
    private var nextIndex = 0
    private(set) var matches: [Int] = []
    init(count: Int) { self.count = count }
    func take() -> Range<Int>? {
        lock.lock(); defer { lock.unlock() }
        guard nextIndex < count else { return nil }
        let start = nextIndex
        nextIndex = min(count, start + SearchPipeline.batchSize)
        return start..<nextIndex
    }
    func append(_ indices: [Int]) { lock.lock(); matches.append(contentsOf: indices); lock.unlock() }
}

/// Results are read only after all preparation workers join. Every publication
/// holds the same lock, so array storage never mutates concurrently.
private final class SearchPreparation {
    private let chunks: SearchChunks
    private let lock = NSLock()
    private(set) var documents: [SearchDocument?]
    init(count: Int) {
        chunks = SearchChunks(count: count)
        documents = Array(repeating: nil, count: count)
    }
    func take() -> Range<Int>? { chunks.take() }
    func append(_ batch: [(Int, SearchDocument)]) {
        lock.lock(); defer { lock.unlock() }
        for (index, document) in batch { documents[index] = document }
    }
}
