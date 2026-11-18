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
    /// Converts a scroll gesture over the card strip into a sideways pan in points (positive shows earlier cards).
    /// Horizontal trackpad swipes pan directly; a vertical wheel or swipe pans too, since the strip only moves sideways.
    /// Line-based wheel deltas (a plain mouse) are scaled to points. Returns nil when there is nothing to move.
    /// Whether a scroll event pans the card strip: only over the strip, and never while the filter card is open, since
    /// the card floats over the strip and scrolls its own content when the shelf is too short for it.
    static func pansStrip(pointerOverStrip: Bool, filterCardOpen: Bool) -> Bool { pointerOverStrip && !filterCardOpen }

    static func panDelta(deltaX: CGFloat, deltaY: CGFloat, precise: Bool) -> CGFloat? {
        let raw = abs(deltaY) > abs(deltaX) ? deltaY : deltaX
        guard raw != 0 else { return nil }
        return precise ? raw : raw * 12
    }
}
