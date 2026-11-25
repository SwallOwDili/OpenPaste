import SwiftUI

/// Card outline, shadow and header metrics. Values change from macOS 26.
enum CardChrome {
    static let modern: Bool = { if #available(macOS 26, *) { true } else { false } }()
    /// Corner radius of a card: 16 with a continuous curve from macOS 26, 10 with a circular one before.
    static let radius: CGFloat = modern ? 16 : 10
    /// The selection ring sits behind the card, 4 pt larger on every side, so its radius is 4 more.
    static let ringInset: CGFloat = 4
    static let ringRadius: CGFloat = radius + ringInset
    /// Shadow: black 8% without offset from macOS 26, black 10% dropped by 1 pt before.
    /// The radius is the SwiftUI value (half the AppKit blur of 2).
    static let shadowOpacity: Double = modern ? 0.08 : 0.1
    static let shadowOffsetY: CGFloat = modern ? 0 : 1
    static let shadowRadius: CGFloat = 1

    /// Opacity of the header's source icon on a card whose cover fills it: the icon should not compete with the picture.
    static let coverIconOpacity: Double = 0.5

    /// Rounded rectangle with the card's curve style; `radius` defaults to the card's own.
    static func shape(radius: CGFloat = CardChrome.radius) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: modern ? .continuous : .circular)
    }

    /// Header size class, from the card's height: a card under 200 pt tall, or the compact setting, is `compact`.
    /// An unknown height (0 or less) counts as `regular`.
    enum HeaderClass {
        case compact, small, regular, large
        init(cardHeight: CGFloat, compact: Bool) {
            if compact || (cardHeight > 0 && cardHeight < 200) { self = .compact }
            else if cardHeight >= 280 { self = .large }
            else if cardHeight >= 240 || cardHeight <= 0 { self = .regular }
            else { self = .small }
        }
    }
    static func compactHeader(cardHeight: CGFloat, compact: Bool) -> Bool { HeaderClass(cardHeight: cardHeight, compact: compact) == .compact }
    /// Space kept free right of the header title: 70 / 66 / 62 by class, 30 next to the small compact icon.
    static func titleTrailing(cardHeight: CGFloat, compact: Bool) -> CGFloat {
        switch HeaderClass(cardHeight: cardHeight, compact: compact) {
        case .compact: 30
        case .large: 70
        case .regular: 66
        case .small: 62
        }
    }
    /// Header height: 56 / 52 / 48 by class, 34 (36 from macOS 26) when compact.
    static func headerHeight(cardHeight: CGFloat, compact: Bool) -> CGFloat {
        switch HeaderClass(cardHeight: cardHeight, compact: compact) {
        case .compact: modern ? 36 : 34
        case .large: 56
        case .regular: 52
        case .small: 48
        }
    }
}
