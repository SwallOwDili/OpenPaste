import Foundation

struct PermissionState: Equatable {
    let accessibility: Bool
    let eventPosting: Bool

    var directPasteAllowed: Bool { accessibility && eventPosting }
    var status: String {
        directPasteAllowed ? "已授权" : (accessibility ? "辅助功能已开，按键权限未生效" : "系统尚未识别授权")
    }
}

/// Runs permission preflights away from the UI thread. Refreshes received while
/// a query is active are collapsed into one follow-up query. Every completed
/// sample is published on the main queue before that follow-up begins.
final class PermissionMonitor {
    typealias Query = () -> PermissionState
    typealias Publish = (PermissionState) -> Void

    private let queue: DispatchQueue
    private let query: Query
    private let publish: Publish
    private let lock = NSLock()
    private var requestedGeneration = 0
    private var activeGeneration: Int?

    init(
        queue: DispatchQueue = DispatchQueue(label: "openpaste.permission-monitor", qos: .utility),
        query: @escaping Query,
        publish: @escaping Publish
    ) {
        self.queue = queue
        self.query = query
        self.publish = publish
    }

    func refresh() {
        lock.lock()
        requestedGeneration += 1
        guard activeGeneration == nil else { lock.unlock(); return }
        let generation = requestedGeneration
        activeGeneration = generation
        lock.unlock()
        perform(generation)
    }

    private func perform(_ generation: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            let state = query()
            DispatchQueue.main.async { [weak self] in self?.complete(state, generation: generation) }
        }
    }

    private func complete(_ state: PermissionState, generation: Int) {
        precondition(Thread.isMainThread, "Permission state must be published on the main thread")
        lock.lock()
        let next: Int?
        if requestedGeneration != generation {
            next = requestedGeneration; activeGeneration = next
        } else { next = nil; activeGeneration = nil }
        lock.unlock()
        publish(state)
        if let next { perform(next) }
    }
}
