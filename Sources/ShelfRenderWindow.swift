import Foundation

enum ShelfRenderWindow {
    static let batchSize = 64

    static func initialCount(total: Int) -> Int {
        min(max(0, total), batchSize)
    }

    static func nextCount(current: Int, total: Int) -> Int {
        min(max(0, total), max(batchSize, current + batchSize))
    }

    static func countIncluding(index: Int, total: Int) -> Int {
        guard index >= 0, total > 0 else { return initialCount(total: total) }
        let batches = (index / batchSize) + 1
        return min(total, batches * batchSize)
    }

    static func resetCount(total: Int, selectedIndex: Int?) -> Int {
        guard let selectedIndex else { return initialCount(total: total) }
        return countIncluding(index: selectedIndex, total: total)
    }
}
