import CoreGraphics

/// Layout of the shelf's card strip, including the Dock-style magnification shown while the arrow keys are used.
///
/// The strip places its own cards: there is no scroll view underneath, so where a card is drawn and where the strip is
/// scrolled to are one and the same number. Three continuous inputs describe a frame:
/// - `focus`, a fractional card index that glides from one card to the next (the magnified spot, kept in the middle);
/// - `intensity`, 0...1: 0 draws every card at its full size with the original spacing, 1 is the full Dock effect
///   (far cards at `restScale`, the focus card at full size, a cosine fall-off in between);
/// - `pan`, a sideways shift in points from the trackpad or mouse wheel, limited so neither end of the strip leaves a gap.
enum CardMagnification {
    /// Drawn scale of cards outside the magnified area at full intensity.
    static let restScale: CGFloat = 0.62
    /// Number of cards from the focus over which the scale falls from 1 to the far scale.
    static let reach = 3.0
    /// Horizontal spacing between cards.
    static let spacing: CGFloat = 12
    /// Space before the first card and after the last one.
    static let stripLeading: CGFloat = 20
    /// Space above and below the cards.
    static let stripVerticalPadding: CGFloat = 8
    /// Selection jumps farther than this many cards snap instead of gliding (search, filters, Home/End).
    static let glideLimit = 6.0
    /// Seconds after the last arrow key press before the effect fades out.
    static let holdSeconds = 0.9

    /// Full width of a card on the shelf. Every place that needs the card width uses this.
    static func cardWidth(compact: Bool) -> CGFloat { compact ? 180 : 240 }

    /// Scale of cards far from the focus: 1 without the effect, `restScale` with it.
    static func farScale(intensity: Double) -> CGFloat {
        1 - (1 - restScale) * CGFloat(min(max(intensity, 0), 1))
    }

    /// Scale of a card whose centre is `distance` cards from the focus.
    static func scale(distance: Double, intensity: Double) -> CGFloat {
        let far = farScale(intensity: intensity)
        let step = abs(distance)
        guard step < reach else { return far }
        let bell = 0.5 * (1 + cos(Double.pi * step / reach))
        return far + (1 - far) * CGFloat(bell)
    }

    /// Where the drawn cards sit relative to the left edge of the first card, for one focus and intensity.
    struct DrawnLayout {
        let focus: Double
        let count: Int
        let cardWidth: CGFloat
        let intensity: Double
        private let far: CGFloat
        private let first: Int
        private var window: [CGFloat] = []

        init(focus: Double, count: Int, cardWidth: CGFloat, intensity: Double) {
            self.count = count
            self.cardWidth = cardWidth
            self.intensity = intensity
            self.focus = min(max(focus, 0), Double(max(count - 1, 0)))
            far = cardWidth * CardMagnification.farScale(intensity: intensity)
            first = max(0, Int((self.focus - CardMagnification.reach).rounded(.down)) - 1)
            let last = min(count - 1, Int((self.focus + CardMagnification.reach).rounded(.up)) + 1)
            guard count > 0, first <= last else { return }
            var centre = first == 0 ? width(0) / 2 : far / 2 + CGFloat(first) * (far + CardMagnification.spacing)
            window.append(centre)
            var index = first
            while index < last {
                centre += (width(index) + width(index + 1)) / 2 + CardMagnification.spacing
                window.append(centre)
                index += 1
            }
        }

        func width(_ index: Int) -> CGFloat {
            cardWidth * CardMagnification.scale(distance: Double(index) - focus, intensity: intensity)
        }

        /// Centre of card `index`, measured from the left edge of card 0. Increases with the index.
        func centre(_ index: Int) -> CGFloat {
            guard count > 0, !window.isEmpty else { return 0 }
            if index < first { return far / 2 + CGFloat(index) * (far + CardMagnification.spacing) }
            let last = first + window.count - 1
            if index > last { return window[window.count - 1] + CGFloat(index - last) * (far + CardMagnification.spacing) }
            return window[index - first]
        }

        /// The focus as a point on the strip (between two card centres when the focus is fractional).
        var focusPoint: CGFloat {
            let base = min(Int(focus.rounded(.down)), max(count - 1, 0))
            let next = min(base + 1, max(count - 1, 0))
            return centre(base) + CGFloat(focus - Double(base)) * (centre(next) - centre(base))
        }

        var leftEdge: CGFloat { count > 0 ? centre(0) - width(0) / 2 : 0 }
        var rightEdge: CGFloat { count > 0 ? centre(count - 1) + width(count - 1) / 2 : 0 }
    }

    /// One drawn frame of the strip, in viewport coordinates (0 is the left edge of the visible strip).
    struct Frame {
        let layout: DrawnLayout
        /// Left edge of card 0. Anything shown before the cards (the translation placeholder) ends `spacing` before it.
        let firstLeft: CGFloat
        /// Width reserved before card 0 for the translation placeholder (its width plus the spacing), or 0.
        let leading: CGFloat
        let viewport: CGFloat
        /// The pan this frame allows: beyond it one end of the strip would come away from the edge.
        let panRange: ClosedRange<CGFloat>
        /// The pan actually applied (the requested one limited to `panRange`).
        let pan: CGFloat

        var count: Int { layout.count }
        func centre(_ index: Int) -> CGFloat { firstLeft + layout.centre(index) - layout.leftEdge }
        func scale(_ index: Int) -> CGFloat { CardMagnification.scale(distance: Double(index) - layout.focus, intensity: layout.intensity) }
        func width(_ index: Int) -> CGFloat { layout.width(index) }
        func left(_ index: Int) -> CGFloat { centre(index) - width(index) / 2 }
        func right(_ index: Int) -> CGFloat { centre(index) + width(index) / 2 }

        /// Cards that overlap the viewport (widened by `margin` on both sides). Only these are built.
        func visible(margin: CGFloat = CardMagnification.spacing) -> Range<Int> {
            guard count > 0 else { return 0..<0 }
            let half = layout.cardWidth / 2
            // First card whose right edge reaches the viewport, and first card that starts beyond it. Centres increase
            // with the index, so both are binary searches.
            func firstIndex(where condition: (Int) -> Bool) -> Int {
                var low = 0, high = count
                while low < high {
                    let mid = (low + high) / 2
                    if condition(mid) { high = mid } else { low = mid + 1 }
                }
                return low
            }
            let lower = firstIndex { centre($0) + half >= -margin }
            let upper = firstIndex { centre($0) - half > viewport + margin }
            return lower..<max(lower, upper)
        }
    }

    /// The frame for one focus, intensity and pan. Without pan the focus card is in the middle of the viewport, except
    /// near the ends, where the strip stops at `stripLeading` from the edge instead of leaving a gap.
    static func frame(focus: Double, count: Int, cardWidth: CGFloat, viewport: CGFloat, intensity: Double,
                      extraLeading: CGFloat = 0, pan: CGFloat = 0) -> Frame {
        let layout = DrawnLayout(focus: focus, count: count, cardWidth: cardWidth, intensity: intensity)
        let point = layout.focusPoint
        var centre = viewport / 2
        centre = max(centre, viewport - stripLeading - (layout.rightEdge - point))
        centre = min(centre, stripLeading + extraLeading + (point - layout.leftEdge))
        let restLeft = centre - (point - layout.leftEdge)
        let span = layout.rightEdge - layout.leftEdge
        // Panning right may bring the start of the strip to its padding, panning left the end of the strip to its
        // padding; a strip shorter than the viewport cannot pan at all.
        let upper = stripLeading + extraLeading - restLeft
        let lower = min(upper, viewport - stripLeading - span - restLeft)
        let applied = min(max(pan, lower), upper)
        return Frame(layout: layout, firstLeft: restLeft + applied, leading: extraLeading, viewport: viewport,
                     panRange: lower...upper, pan: applied)
    }

    /// The focus whose un-panned frame puts card 0 at `firstLeft`, i.e. the focus that shows the same strip position as a
    /// panned frame. Used to turn a pan back into focus before gliding to a new selection, so the strip does not jump.
    static func focus(showing firstLeft: CGFloat, count: Int, cardWidth: CGFloat, viewport: CGFloat, intensity: Double,
                      extraLeading: CGFloat = 0) -> Double {
        guard count > 1 else { return 0 }
        // card 0 moves left (or stays) as the focus moves right.
        var low = 0.0, high = Double(count - 1)
        for _ in 0..<40 {
            let mid = (low + high) / 2
            let left = frame(focus: mid, count: count, cardWidth: cardWidth, viewport: viewport, intensity: intensity,
                             extraLeading: extraLeading).firstLeft
            if left > firstLeft { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }
}
