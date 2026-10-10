import AppKit

/// Pure helpers for the shelf interactions (board switching,
/// preview paging, wheel scrolling), kept free of windows so they can be unit tested.
enum BoardNavigation {
    /// Cycles through history (`nil`) followed by every board; wraps at both ends.
    static func next(from current: UUID?, boards: [UUID], delta: Int) -> UUID?? {
        guard !boards.isEmpty, delta != 0 else { return nil }
        let order: [UUID?] = [nil] + boards.map { Optional($0) }
        let index = order.firstIndex(where: { $0 == current }) ?? 0
        let count = order.count
        return .some(order[((index + delta) % count + count) % count])
    }
}

enum HorizontalWheel {
    /// Converts a vertical wheel gesture into a horizontal offset for a list that
    /// only scrolls sideways. Returns nil when the gesture is already horizontal
    /// (or has no vertical part) so the system handles it unchanged.
    static func offset(current: CGFloat, deltaX: CGFloat, deltaY: CGFloat, precise: Bool,
                       contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat? {
        guard abs(deltaY) > abs(deltaX), deltaY != 0 else { return nil }
        let scaled = precise ? deltaY : deltaY * 12
        let maximum = max(0, contentWidth - viewportWidth)
        return min(maximum, max(0, current - scaled))
    }
}
