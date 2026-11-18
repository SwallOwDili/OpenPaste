import AppKit
import SwiftUI

/// Critically-overdamped-style spring (no bounce) that moves a fractional card index towards a target. The mass,
/// stiffness and damping are the ones the common Dock re-creations use; the velocity carries over when the target
/// moves again, so held arrow keys glide instead of restarting.
struct FocusSpring {
    var value: Double
    var velocity = 0.0
    var target: Double
    static let mass = 0.1, stiffness = 170.0, damping = 12.0
    /// The focus never trails the target by more than this many cards, so with held keys the selected card stays
    /// within a card of the middle instead of racing ahead while the spring catches up.
    static let maxLag = 1.0

    /// Whether `maxLag` applies. Only arrow-key moves need it; a click glides the whole way.
    var lagLimited = true

    var settled: Bool { abs(value - target) < 0.002 && abs(velocity) < 0.01 }

    /// Keeps the focus within `maxLag` cards of the target.
    mutating func limitLag() {
        guard lagLimited else { return }
        if value < target - Self.maxLag { value = target - Self.maxLag }
        else if value > target + Self.maxLag { value = target + Self.maxLag }
    }

    mutating func advance(by seconds: Double) {
        var remaining = min(max(seconds, 0), 0.1)
        let step = 1.0 / 480.0
        while remaining > 0 {
            let dt = min(step, remaining)
            let acceleration = (-Self.stiffness * (value - target) - Self.damping * velocity) / Self.mass
            velocity += acceleration * dt
            value += velocity * dt
            remaining -= dt
        }
        limitLag()
        if settled { value = target; velocity = 0 }
    }
}

/// The strength of the magnification, 0...1. It rises quickly while the arrow keys are in use and falls back to 0 once
/// they have been left alone for `holdSeconds`, so the cards are at their normal size whenever the user is not navigating.
struct MagnifyEnvelope {
    var value = 0.0
    /// Seconds since the last arrow-key move; nil when none happened or the effect has faded out.
    var sinceLastKey: Double?
    static let riseRate = 14.0, fallRate = 4.0

    var goal: Double { (sinceLastKey ?? .infinity) < CardMagnification.holdSeconds ? 1 : 0 }
    var settled: Bool { value == goal && goal == 0 }

    mutating func keyPressed() { sinceLastKey = 0 }
    mutating func reset() { value = 0; sinceLastKey = nil }

    mutating func advance(by seconds: Double) {
        let dt = min(max(seconds, 0), 0.1)
        if let t = sinceLastKey { sinceLastKey = t + dt }
        let target = goal
        let rate = target > value ? Self.riseRate : Self.fallRate
        value += (target - value) * min(1, dt * rate)
        if abs(target - value) < 0.003 { value = target }
        if value == 0, goal == 0 { sinceLastKey = nil }
    }
}

/// The strip's whole position: one shared, animated focus, the magnification strength and the sideways pan. The strip
/// draws every card from the same frame, so cards can never disagree with each other, and nothing else (no scroll view)
/// holds a position of its own that could drift away from it.
final class FocusDriver: NSObject, ObservableObject {
    private(set) var value = 0.0
    /// Strength of the magnification (0 = every card at its normal size).
    private(set) var intensity = 0.0
    private var envelope = MagnifyEnvelope()
    /// The card index the focus is heading to (the selection).
    private(set) var target = 0.0
    /// Sideways shift from the trackpad or mouse wheel, in points; positive shows earlier cards.
    private(set) var pan: CGFloat = 0
    private var spring = FocusSpring(value: 0, target: 0)
    private var link: CADisplayLink?
    private var timer: Timer?
    /// The strip's AppKit view. The display link is made from it, so the animation runs at the refresh rate of the
    /// screen the shelf is on, and the preview popover is anchored to it.
    weak var hostView: NSView?

    /// Strip geometry as last drawn; needed to turn a pan into focus and to clamp scrolling between frames.
    struct Geometry: Equatable {
        var count: Int
        var cardWidth: CGFloat
        var size: CGSize
        var extraLeading: CGFloat
    }
    private(set) var geometry: Geometry?

    /// Moves the focus to `index`. It glides unless `animated` is false, motion is reduced or the jump is longer than
    /// `glideLimit` cards (search, filters, Home/End), in which case it snaps.
    /// - Parameters:
    ///   - keyboard: the move came from an arrow key, so a held key keeps the focus within `maxLag` of the selection.
    ///   - magnify: turn the Dock effect on for a while (arrow keys with the setting on).
    func move(to index: Int, animated: Bool = true, keyboard: Bool = false, magnify: Bool = false) {
        rebasePan()
        target = Double(index)
        spring.target = target
        spring.lagLimited = keyboard
        spring.limitLag()
        let glide = animated && abs(target - spring.value) <= CardMagnification.glideLimit
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if glide {
            if magnify { envelope.keyPressed() }
        } else {
            spring.value = target; spring.velocity = 0
        }
        value = spring.value
        if spring.settled && envelope.settled { stop() } else { start() }
        objectWillChange.send()
    }

    /// Puts the focus on `index` at once and drops any pan (the shelf was opened, the strip appeared).
    func snap(to index: Int) {
        pan = 0
        move(to: index, animated: false)
    }

    /// The selected card's index changed without a new selection (a clip was inserted or removed before it): shift the
    /// focus with it so the same card stays where it is, keeping any pan.
    func follow(index: Int) {
        let delta = Double(index) - target
        guard delta != 0 else { return }
        target += delta
        spring.target = target
        spring.value += delta
        value = spring.value
        objectWillChange.send()
    }

    /// Scrolls the strip sideways by `delta` points (positive shows earlier cards), within the ends of the strip.
    func scroll(by delta: CGFloat) {
        guard delta != 0, let geometry else { return }
        let range = CardMagnification.frame(focus: value, count: geometry.count, cardWidth: geometry.cardWidth,
                                            viewport: geometry.size.width, intensity: intensity,
                                            extraLeading: geometry.extraLeading, pan: pan).panRange
        let next = min(max(pan + delta, range.lowerBound), range.upperBound)
        guard next != pan else { return }
        pan = next
        objectWillChange.send()
    }

    /// Before moving to a new selection, turns the pan into an equivalent focus so the glide starts from what is on
    /// screen instead of jumping back to the old selection first.
    private func rebasePan() {
        guard pan != 0, let geometry else { pan = 0; return }
        let shown = CardMagnification.frame(focus: value, count: geometry.count, cardWidth: geometry.cardWidth,
                                            viewport: geometry.size.width, intensity: intensity,
                                            extraLeading: geometry.extraLeading, pan: pan).firstLeft
        let focus = CardMagnification.focus(showing: shown, count: geometry.count, cardWidth: geometry.cardWidth,
                                            viewport: geometry.size.width, intensity: intensity,
                                            extraLeading: geometry.extraLeading)
        pan = 0
        spring.value = focus; spring.velocity = 0
        value = focus
    }

    /// Most cards kept built at once (the old shelf's render batch). Cards are expensive to build (rich text, images,
    /// link previews), so a card stays built after it leaves the screen until the strip moves far away from it.
    static let keptCards = 64
    private var kept: Range<Int> = 0..<0

    /// The cards to keep built for the cards now on screen: those plus about a screen on either side, and any built
    /// before that are still within `keptCards` of them, so scrolling back and forth never rebuilds the same cards.
    func keptRange(around visible: Range<Int>, count: Int) -> Range<Int> {
        let pad = max(visible.count, 6)
        let wanted = max(0, visible.lowerBound - pad)..<min(count, visible.upperBound + pad)
        let previous = kept.clamped(to: 0..<count)
        let union = min(previous.lowerBound, wanted.lowerBound)..<max(previous.upperBound, wanted.upperBound)
        kept = !previous.isEmpty && union.count <= Self.keptCards ? union : wanted
        return kept
    }

    private struct FrameKey: Equatable {
        let value: Double, intensity: Double, pan: CGFloat
        let geometry: Geometry
    }
    private var cachedFrame: (key: FrameKey, frame: CardMagnification.Frame)?

    /// The frame the strip draws for the current focus, intensity and pan. Built once per change and reused.
    func frame(count: Int, cardWidth: CGFloat, size: CGSize, extraLeading: CGFloat) -> CardMagnification.Frame {
        let geometry = Geometry(count: count, cardWidth: cardWidth, size: size, extraLeading: extraLeading)
        self.geometry = geometry
        let key = FrameKey(value: value, intensity: intensity, pan: pan, geometry: geometry)
        if let cachedFrame, cachedFrame.key == key { return cachedFrame.frame }
        let frame = CardMagnification.frame(focus: value, count: count, cardWidth: cardWidth, viewport: size.width,
                                            intensity: intensity, extraLeading: extraLeading, pan: pan)
        cachedFrame = (key, frame)
        return frame
    }

    /// Where card `index` rests once it is selected and the strip has settled (full size, in the middle), in the
    /// strip view's coordinates; nil when that place is off screen or the strip has not been drawn yet. Used to anchor
    /// the preview popover to the card it shows.
    func restingRect(index: Int) -> CGRect? {
        guard let geometry, let view = hostView, index >= 0, index < geometry.count else { return nil }
        let frame = CardMagnification.frame(focus: Double(index), count: geometry.count, cardWidth: geometry.cardWidth,
                                            viewport: geometry.size.width, intensity: 0, extraLeading: geometry.extraLeading,
                                            pan: Double(index) == target ? pan : 0)
        let padding = CardMagnification.stripVerticalPadding
        let rect = CGRect(x: frame.left(index), y: padding, width: frame.width(index),
                          height: max(40, geometry.size.height - padding * 2))
        guard rect.maxX > 0, rect.minX < min(geometry.size.width, view.bounds.width) else { return nil }
        return rect
    }

    private func start() {
        guard link == nil, timer == nil else { return }
        // A display link only ticks for a window on screen; anything else (a hidden shelf, an off-screen render) uses a timer.
        if let view = hostView, view.window?.isVisible == true {
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.advance(by: 1.0 / 60.0) }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        lastTick = nil
    }

    private func stop() {
        link?.invalidate(); link = nil
        timer?.invalidate(); timer = nil
    }

    private var lastTick: CFTimeInterval?
    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        advance(by: now - (lastTick ?? link.timestamp))
        lastTick = now
    }

    private func advance(by seconds: Double) {
        spring.advance(by: seconds)
        value = spring.value
        envelope.advance(by: seconds)
        intensity = envelope.value
        objectWillChange.send()
        if spring.settled && envelope.settled { stop() }
    }
}
