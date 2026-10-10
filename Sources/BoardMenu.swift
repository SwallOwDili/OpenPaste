import AppKit
import SwiftUI

/// Colour names a board can use, in the order shown in its context menu.
enum BoardPalette {
    static let names = ["红色", "橙色", "黄色", "绿色", "青色", "蓝色", "紫色", "灰色"]
    static func nsColor(_ name: String?) -> NSColor {
        switch name {
        case "橙色": return .systemOrange
        case "黄色": return .systemYellow
        case "绿色": return .systemGreen
        case "青色": return .systemCyan
        case "蓝色": return .systemBlue
        case "紫色": return .systemPurple
        case "灰色": return .systemGray
        default: return .systemRed
        }
    }
}

private final class SwatchView: NSView {
    let name: String
    let selected: Bool
    let onPick: (String) -> Void
    init(name: String, selected: Bool, onPick: @escaping (String) -> Void) {
        self.name = name; self.selected = selected; self.onPick = onPick
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        toolTip = name
        setAccessibilityRole(.button); setAccessibilityLabel(name)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let dot = bounds.insetBy(dx: 4, dy: 4)
        BoardPalette.nsColor(name).setFill()
        NSBezierPath(ovalIn: dot).fill()
        if selected {
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5)); ring.lineWidth = 2; ring.stroke()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            let outer = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)); outer.lineWidth = 1; outer.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { onPick(name) }
    override var acceptsFirstResponder: Bool { false }
}

/// One row of colour dots that lives inside a board's context menu.
private final class ColorRowView: NSView {
    init(current: String?, onPick: @escaping (String) -> Void) {
        let size: CGFloat = 26, gap: CGFloat = 6, inset: CGFloat = 14
        let width = inset * 2 + CGFloat(BoardPalette.names.count) * size + CGFloat(BoardPalette.names.count - 1) * gap
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: size + 14))
        for (index, name) in BoardPalette.names.enumerated() {
            let swatch = SwatchView(name: name, selected: (current ?? "红色") == name, onPick: onPick)
            swatch.frame.origin = NSPoint(x: inset + CGFloat(index) * (size + gap), y: 7)
            addSubview(swatch)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

enum BoardMenuBuilder {
    /// 重命名 / 删除 on top, a divider, then the colour row.
    @MainActor
    static func menu(for board: Board, rename: @escaping () -> Void, delete: @escaping () -> Void, pick: @escaping (String) -> Void) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let renameItem = ClosureMenuItem(title: "重命名", handler: rename)
        let deleteItem = ClosureMenuItem(title: "删除收藏板（保留内容）…", handler: delete)
        menu.addItem(renameItem); menu.addItem(deleteItem); menu.addItem(.separator())
        let colors = NSMenuItem()
        colors.view = ColorRowView(current: board.color) { [weak menu] name in
            menu?.cancelTracking()
            pick(name)
        }
        menu.addItem(colors)
        return menu
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// Transparent overlay that only claims right-clicks (and Control-clicks), so left clicks,
/// drops and hover reach the SwiftUI view underneath.
struct RightClickMenu: NSViewRepresentable {
    let makeMenu: () -> NSMenu
    func makeNSView(context: Context) -> RightClickView { RightClickView() }
    func updateNSView(_ view: RightClickView, context: Context) { view.makeMenu = makeMenu }
    final class RightClickView: NSView {
        var makeMenu: (() -> NSMenu)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isContext = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isContext && bounds.contains(convert(point, from: superview)) ? self : nil
        }
        override func rightMouseDown(with event: NSEvent) { present(event) }
        override func mouseDown(with event: NSEvent) { if event.modifierFlags.contains(.control) { present(event) } }
        private func present(_ event: NSEvent) {
            guard let menu = makeMenu?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
