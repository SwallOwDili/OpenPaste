import AppKit
import SwiftUI

/// Transparency checkerboard behind image cards: a 16 pt pattern with two 8 pt squares on the diagonal,
/// black 5% in light appearance and white 5% in dark, over the card background.
struct Checkerboard: View {
    @Environment(\.colorScheme) private var colorScheme
    static let cell: CGFloat = 8
    var body: some View {
        Canvas { context, size in
            let cell = Self.cell
            var path = Path()
            var row = 0, y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : cell
                while x < size.width { path.addRect(CGRect(x: x, y: y, width: cell, height: cell)); x += cell * 2 }
                y += cell; row += 1
            }
            context.fill(path, with: .color((colorScheme == .dark ? Color.white : Color.black).opacity(0.05)))
        }
    }
}

/// Capsule backdrop of the labels over an image card.
struct CardLabelBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu; view.blendingMode = .withinWindow; view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Quick-paste badge of a card, the modifier symbol and the index in a capsule.
/// `label` is the symbol followed by one digit, e.g. "⌘1".
struct ShortcutBadge: View {
    let label: String
    var onDark: Bool? = nil
    @Environment(\.colorScheme) private var colorScheme
    static func parts(_ label: String) -> (symbol: String, number: String) { (String(label.dropLast()), String(label.suffix(1))) }
    var body: some View {
        let parts = Self.parts(label)
        HStack(spacing: 4) {
            if !parts.symbol.isEmpty { Text(parts.symbol).font(.system(size: 10)) }
            Text(parts.number).font(.system(size: 12)).monospacedDigit()
        }
        .foregroundStyle(Color(nsColor: RichTextRendering.footerColor(onDark: onDark ?? (colorScheme == .dark))))
        .padding(.horizontal, 6).frame(height: 18)
        .background { CardLabelBackdrop().clipShape(RoundedRectangle(cornerRadius: 9, style: .circular)) }
    }
}
